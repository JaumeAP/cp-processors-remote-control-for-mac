using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CPRemote.Windows;

/// <summary>
/// Places elements on a canvas in the units of a manual's figure: the figure's
/// top-left corner is the origin and one unit is one unit of the figure. Used by
/// the CP650, whose figure gives its outline in those units.
/// </summary>
internal sealed class FigureStage
{
    private readonly Canvas _canvas;
    private readonly double _originX;
    private readonly double _originY;

    public FigureStage(Canvas canvas, double originX, double originY)
    {
        _canvas = canvas;
        _originX = originX;
        _originY = originY;
    }

    /// <summary>Adds the element over the figure rectangle x1 to x2 by y1 to y2.</summary>
    public T Box<T>(T element, double x1, double y1, double x2, double y2)
        where T : FrameworkElement
    {
        element.Width = x2 - x1;
        element.Height = y2 - y1;
        Add(element, x1 - _originX, y1 - _originY);
        return element;
    }

    /// <summary>Adds the element centred on the figure point (x, y), at its current size.</summary>
    public void Centre(FrameworkElement element, double x, double y) =>
        Add(element, x - _originX - element.Width / 2, y - _originY - element.Height / 2);

    private void Add(UIElement element, double left, double top)
    {
        _canvas.Children.Add(element);
        Canvas.SetLeft(element, left);
        Canvas.SetTop(element, top);
    }
}

/// <summary>
/// Places elements on a canvas by fractions of its width and height, as the
/// macOS panels do. Sizes given as fractions of the height keep the proportions
/// of the panel. The canvas is drawn in its own units and the window scales it.
/// </summary>
internal sealed class FractionStage
{
    private readonly Canvas _canvas;
    private readonly double _width;
    private readonly double _height;

    public FractionStage(Canvas canvas, double width, double height)
    {
        _canvas = canvas;
        _width = width;
        _height = height;
        canvas.Width = width;
        canvas.Height = height;
    }

    /// <summary>Adds the element as a rectangle dw by dh (fractions of the width and height), centred at x, y.</summary>
    public T Box<T>(T element, double x, double y, double dw, double dh)
        where T : FrameworkElement
    {
        element.Width = _width * dw;
        element.Height = _height * dh;
        Put(element, x, y);
        return element;
    }

    /// <summary>Adds a disc of diameter d (a fraction of the height), centred at x, y.</summary>
    public T Disc<T>(T element, double x, double y, double d)
        where T : FrameworkElement
    {
        element.Width = _height * d;
        element.Height = _height * d;
        Put(element, x, y);
        return element;
    }

    /// <summary>Adds the element, at its own size, centred at x, y.</summary>
    public void Put(FrameworkElement element, double x, double y)
    {
        _canvas.Children.Add(element);
        Canvas.SetLeft(element, _width * x - element.Width / 2);
        Canvas.SetTop(element, _height * y - element.Height / 2);
    }

    /// <summary>
    /// Adds text centred at x, y, sized as a fraction of the height, in a box
    /// <paramref name="width"/> of the panel wide. Returns the text, to change it later.
    /// </summary>
    public TextBlock Label(string text, double x, double y, double size, double width,
        FontWeight weight, bool italic, Brush brush)
    {
        TextBlock block = PanelText.Block(text, _height * size, weight, italic, brush);
        var box = new Grid
        {
            Width = _width * width,
            Height = _height * size * (text.Contains('\n') ? 2.6 : 1.6),
            Children = { block },
        };
        Put(box, x, y);
        return block;
    }
}

/// <summary>Text blocks and glyphs of the panels.</summary>
internal static class PanelText
{
    /// <summary>The font of the Windows symbol glyphs (the counterpart of the SF Symbols the macOS app uses).</summary>
    public const string GlyphFont = "Segoe MDL2 Assets";

    // Glyphs of GlyphFont, by the symbol they stand for. Built from code points so the source stays ASCII.
    public static readonly string MuteGlyph = new((char)0xE74F, 1);
    public static readonly string VolumeGlyph = new((char)0xE767, 1);
    public static readonly string PowerGlyph = new((char)0xE7E8, 1);
    public static readonly string EditGlyph = new((char)0xE70F, 1);
    public static readonly string ListGlyph = new((char)0xE8FD, 1);
    public static readonly string ChevronUpGlyph = new((char)0xE70E, 1);
    public static readonly string ChevronDownGlyph = new((char)0xE70D, 1);
    public static readonly string ChevronLeftGlyph = new((char)0xE76B, 1);
    public static readonly string ChevronRightGlyph = new((char)0xE76C, 1);
    public static readonly string UndoGlyph = new((char)0xE7A7, 1);

    /// <summary>A one-character string from a Unicode code point, for the symbols the macOS panels draw as text.</summary>
    public static string Symbol(int codePoint) => new((char)codePoint, 1);

    /// <summary>A text block at the given size; its lines are centred vertically in the space it is given.</summary>
    public static TextBlock Block(string text, double fontSize, FontWeight weight, bool italic, Brush brush,
        TextAlignment alignment = TextAlignment.Center, string fontFamily = "Segoe UI") => new()
    {
        Text = text,
        FontSize = fontSize,
        FontWeight = weight,
        FontStyle = italic ? FontStyles.Italic : FontStyles.Normal,
        FontFamily = new FontFamily(fontFamily),
        Foreground = brush,
        TextAlignment = alignment,
        TextWrapping = TextWrapping.NoWrap,
        VerticalAlignment = VerticalAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Stretch,
    };
}

/// <summary>Plain shapes of the panels.</summary>
internal static class PanelShape
{
    public static Rectangle Rect(Brush fill, double radius = 0) => new()
    {
        Fill = fill,
        RadiusX = radius,
        RadiusY = radius,
        Stretch = Stretch.Fill,
    };
}

/// <summary>Round keys that do nothing: they are drawn, not pressed.</summary>
internal static class Decoration
{
    /// <summary>
    /// A disc of the given diameter with an optional glyph, in the units of the
    /// panel. It is drawn in a square of 100 units and scaled to the diameter, so
    /// the stroke and the glyph keep their proportions to the key.
    /// </summary>
    public static Viewbox Key(double diameter, Brush face, Brush stroke, double strokeWidth,
        string glyph, Brush glyphBrush, double glyphSize, string fontFamily)
    {
        double scale = 100 / diameter;
        var disc = new Grid { Width = 100, Height = 100 };
        disc.Children.Add(new Ellipse
        {
            Width = 100,
            Height = 100,
            Stretch = Stretch.Fill,
            Fill = face,
            Stroke = stroke,
            StrokeThickness = strokeWidth * scale,
        });
        if (glyph.Length > 0)
        {
            disc.Children.Add(PanelText.Block(glyph, glyphSize * scale, FontWeights.Bold, false, glyphBrush,
                TextAlignment.Center, fontFamily));
        }

        return new Viewbox { Stretch = Stretch.Uniform, Width = diameter, Height = diameter, Child = disc };
    }
}

/// <summary>Looks up the brushes and styles the panels share, and makes their key buttons.</summary>
internal static class PanelResources
{
    public static Brush BrushOf(this FrameworkElement owner, string key) => (Brush)owner.FindResource(key);

    public static Style StyleOf(this FrameworkElement owner, string key) => (Style)owner.FindResource(key);

    /// <summary>A key button of the given style and diameter, in the units of the panel.</summary>
    public static Button KeyOf(this FrameworkElement owner, string styleKey, double diameter) => new()
    {
        Style = owner.StyleOf(styleKey),
        Width = diameter,
        Height = diameter,
    };
}

/// <summary>The font size inside a key: the key is drawn in 100 units, so a size in panel units is scaled.</summary>
internal static class KeyUnits
{
    public static double Of(double diameter, double size) => size / diameter * 100;
}
