// The poll: every two seconds the panel is read from the processor, and a
// reply is applied only where the app has not changed the control itself
// since the read began.

import Foundation

extension RemoteModel {
    func startPolling(_ link: any ControlLink) {
        pollTask = Task { [weak self] in
            // Read at once, then every two seconds; connect() does not wait
            // for it, so a link that never answers still shows its state.
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollCycle(link)
                await Monotonic.sleep(for: self.pollInterval)
            }
        }
    }

    func isCurrent(_ link: any ControlLink) -> Bool { processor === link && !Task.isCancelled }

    func pollCycle(_ link: any ControlLink) async {
        guard isCurrent(link) else { return }
        if !linkOpened {
            // A processor that was off, booting or unreachable at connect
            // time is found when it comes up. Once opened, the library
            // re-opens a dropped link itself inside the next read.
            let connected = await link.connect()
            guard isCurrent(link) else { return }
            note("connect \(connected ? "succeeded" : "failed")")
            guard connected else { return }
            linkOpened = true
            formatListDue = true
            resetMacroReads()
        }
        await refresh(link)
    }

    /// A new or reopened link: the macro number and name are read again,
    /// whatever went unanswered on the old one.
    func resetMacroReads() {
        macroMisses = 0
        macroPollsToSkip = 0
    }

    /// One macro read went unanswered.
    func macroReadMissed() {
        macroMisses += 1
        guard macroMisses >= Self.macroMissLimit else { return }
        note("macro reads unanswered: paused for \(Self.macroPausePolls) polls")
        macroMisses = 0
        macroPollsToSkip = Self.macroPausePolls
    }

    /// A reply to a read that started at `start` may update the panel only
    /// if no send of that control is under way, and the control was not
    /// changed here since just before the read.
    func mayApply(_ param: String, readStartedAt start: Monotonic.Instant) -> Bool {
        if sending[param] != nil { return false }
        if let changed = localChange[param], changed > start - Self.pollHoldOff { return false }
        return true
    }

    func refresh(_ link: any ControlLink) async {
        let panel = processorModel.panel
        let faderStart = Monotonic.Instant.now
        let faderReply = await link.get(panel.fader)
        guard isCurrent(link) else { return }
        guard let faderReply else {
            await faderUnanswered(link)
            return
        }
        silentPolls = 0
        let faderRead = Self.faderLevel(faderReply)
        applyFader(faderRead, panel: panel, start: faderStart)
        await readSelection(link, panel: panel)
        // The controls come on only once this pass has read the fader and
        // the mute: enabled earlier, they showed the previous state, and a
        // Mute pressed then sent the opposite of what was meant.
        guard let muteAnswered = await readMute(link, panel: panel) else { return }
        if faderRead != nil, muteAnswered, !panelRead {
            panelRead = true
            note("panel read: controls enabled")
            announceConnectionChange()
        }
        await pollMacro(link, panel: panel)
        await readFormatList(link)
    }

    /// Unanswered: after a few in a row, reopen a link that is open but
    /// hung, and skip the other reads (each would time out too).
    func faderUnanswered(_ link: any ControlLink) async {
        silentPolls += 1
        note("fader read unanswered (\(silentPolls) of \(Self.silentPollLimit)): \(await link.lastError)")
        markUnread("fader read unanswered")
        guard silentPolls >= Self.silentPollLimit else { return }
        note("reopening the link: \(Self.silentPollLimit) fader reads unanswered")
        silentPolls = 0
        formatListDue = true
        resetMacroReads()
        // The user may have disconnected while the error text was read.
        guard isCurrent(link) else { return }
        _ = await reopenLink(link)
    }

    func applyFader(_ level: Double?, panel: PanelProfile, start: Monotonic.Instant) {
        guard let level, mayApply(panel.fader, readStartedAt: start), !isTurningKnob, faderIsSettled, fader != level
        else { return }
        fader = level
    }

    /// The selected button: the CP650's format button, or the CP750's input.
    func readSelection(_ link: any ControlLink, panel: PanelProfile) async {
        let start = Monotonic.Instant.now
        if processorModel == .cp650 {
            await readFormatButton(link, start: start)
        } else if let inputs = panel.inputs {
            await readInput(link, inputs: inputs, start: start)
        }
    }

    func readFormatButton(_ link: any ControlLink, start: Monotonic.Instant) async {
        guard let reply = await link.get(Self.formatButtonParam), isCurrent(link),
            let wireValue = Int(reply), (0...7).contains(wireValue),
            mayApply(Self.formatButtonParam, readStartedAt: start),
            formatButton != wireValue + 1
        else { return }
        formatButton = wireValue + 1
    }

    func readInput(_ link: any ControlLink, inputs: [String], start: Monotonic.Instant) async {
        guard let reply = await link.get(Self.inputParam), isCurrent(link),
            let index = inputs.firstIndex(of: reply),
            mayApply(Self.inputParam, readStartedAt: start),
            formatButton != index + 1
        else { return }
        formatButton = index + 1
    }

    /// Reads the mute and applies it. Returns whether the processor answered,
    /// or nil when the link is no longer the current one.
    func readMute(_ link: any ControlLink, panel: PanelProfile) async -> Bool? {
        let start = Monotonic.Instant.now
        let muteReply = await link.get(panel.mute)
        guard isCurrent(link) else { return nil }
        if let muteReply, mayApply(panel.mute, readStartedAt: start), muted != (muteReply == "1") {
            muted = muteReply == "1"
        }
        return muteReply != nil
    }

    /// The selected macro, for the screen: its number every poll, its name
    /// whenever the name shown is not that macro's. Unanswered reads pause
    /// these reads for a few polls (`macroReadMissed`).
    func pollMacro(_ link: any ControlLink, panel: PanelProfile) async {
        guard let nameParam = panel.macroName else { return }
        if macroPollsToSkip > 0 { macroPollsToSkip -= 1 }
        guard macroPollsToSkip == 0 else { return }
        let presetStart = Monotonic.Instant.now
        let presetReply = await link.get(Self.macroPresetParam)
        guard isCurrent(link) else { return }
        guard let presetReply else {
            macroReadMissed()
            return
        }
        macroMisses = 0
        guard let number = Int(presetReply.trimmingCharacters(in: .whitespaces)),
            mayApply(Self.macroPresetParam, readStartedAt: presetStart)
        else { return }
        if macroNameNumber == number {
            macroPreset = number
        } else {
            await readMacroName(link, number: number, nameParam: nameParam)
        }
    }

    /// The number and its name change together: a new key is never shown
    /// beside the old macro's name.
    func readMacroName(_ link: any ControlLink, number: Int, nameParam: String) async {
        let nameStart = Monotonic.Instant.now
        let nameReply = await link.get(nameParam)
        guard isCurrent(link) else { return }
        guard let nameReply else {
            macroReadMissed()
            // The number without a name, not the old name; as with a named
            // reply, a recent change here keeps its value.
            guard mayApply(Self.macroPresetParam, readStartedAt: nameStart) else { return }
            macroPreset = number
            macroName = nil
            macroNameNumber = nil
            return
        }
        guard mayApply(nameParam, readStartedAt: nameStart),
            mayApply(Self.macroPresetParam, readStartedAt: nameStart)
        else { return }
        macroPreset = number
        macroName = nameReply.trimmingCharacters(in: .whitespaces)
        macroNameNumber = number
    }

    /// The CP650's programmed formats change only in setup: one attempt
    /// per opened link, so a processor that never answers it is not asked
    /// again.
    func readFormatList(_ link: any ControlLink) async {
        guard processorModel == .cp650, formatListDue, isCurrent(link) else { return }
        formatListDue = false
        guard let reply = await link.get("format_list"), isCurrent(link) else { return }
        let labels = reply.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if labels.count == 8, labels.allSatisfy({ !$0.isEmpty }) { programmedFormats = labels }
    }
}
