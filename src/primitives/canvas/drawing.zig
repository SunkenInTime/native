const geometry = @import("geometry");

const ObjectId = u64;
const ImageId = u64;

/// Presentation ownership survives display-list lowering so a platform can
/// composite CPU-retained chrome below an immediate GPU island without
/// teaching either renderer about the widget tree that produced it.
pub const PresentationLayer = enum {
    retained,
    immediate,
};

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb8(r: u8, g: u8, b: u8) Color {
        return rgba8(r, g, b, 255);
    }

    pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }
};

pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn identity() Affine {
        return .{};
    }

    pub fn translate(x: f32, y: f32) Affine {
        return .{ .tx = x, .ty = y };
    }

    pub fn scale(x: f32, y: f32) Affine {
        return .{ .a = x, .d = y };
    }

    pub fn multiply(self: Affine, other: Affine) Affine {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .tx = self.a * other.tx + self.c * other.ty + self.tx,
            .ty = self.b * other.tx + self.d * other.ty + self.ty,
        };
    }

    pub fn transformPoint(self: Affine, point: geometry.PointF) geometry.PointF {
        return .{
            .x = self.a * point.x + self.c * point.y + self.tx,
            .y = self.b * point.x + self.d * point.y + self.ty,
        };
    }

    pub fn transformRect(self: Affine, rect: geometry.RectF) geometry.RectF {
        const normalized = rect.normalized();
        return boundsFromPoints(&.{
            self.transformPoint(normalized.topLeft()),
            self.transformPoint(normalized.topRight()),
            self.transformPoint(normalized.bottomLeft()),
            self.transformPoint(normalized.bottomRight()),
        }) orelse geometry.RectF.zero();
    }

    pub fn inverse(self: Affine) ?Affine {
        const determinant = self.a * self.d - self.b * self.c;
        if (@abs(determinant) <= 0.000001) return null;
        const inv = 1 / determinant;
        return .{
            .a = self.d * inv,
            .b = -self.b * inv,
            .c = -self.c * inv,
            .d = self.a * inv,
            .tx = (self.c * self.ty - self.d * self.tx) * inv,
            .ty = (self.b * self.tx - self.a * self.ty) * inv,
        };
    }
};

pub const Radius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(value: f32) Radius {
        return .{
            .top_left = value,
            .top_right = value,
            .bottom_right = value,
            .bottom_left = value,
        };
    }
};

pub const GradientStop = struct {
    offset: f32,
    color: Color,
};

/// What happens outside the authored stop interval. CSS repeating gradients
/// are `repeat` applied to a linear/radial/conic geometry, not separate paint
/// shapes. `reflect` is kept at this low-level seam because both GPU APIs and
/// image paint systems expose it cheaply even though Weaver's CSS-compatible
/// authoring does not need to surface it initially.
pub const GradientSpread = enum {
    pad,
    repeat,
    reflect,
};

/// Interpolation spaces supported by the current sRGB `Color` storage. Every
/// mode interpolates premultiplied components and then unpremultiplies, matching
/// CSS Color 4's alpha rule. Wider-gamut source colors require a future Color
/// model rather than pretending four sRGB floats carry Display-P3.
pub const GradientInterpolation = enum {
    srgb,
    srgb_linear,
    oklab,
};

pub const LinearGradient = struct {
    start: geometry.PointF,
    end: geometry.PointF,
    stops: []const GradientStop = &.{},
    spread: GradientSpread = .pad,
    interpolation: GradientInterpolation = .srgb_linear,
};

/// Elliptical radial gradient: `center` is t=0 and `radii` is the t=1
/// ellipse. This represents CSS radial-gradient geometry after the author-side
/// size/position keywords have resolved against the final box. Retained views
/// require both radii to be greater than zero; CSS zero-radius degenerates are
/// outside the contract until every backend renders them identically.
pub const RadialGradient = struct {
    center: geometry.PointF,
    radii: geometry.SizeF,
    stops: []const GradientStop = &.{},
    spread: GradientSpread = .pad,
    interpolation: GradientInterpolation = .srgb_linear,
};

/// Conic gradient in the canvas' y-down coordinates. Zero radians points
/// along +x and positive angles turn clockwise. CSS's zero-at-top convention
/// is an authoring conversion (`css_angle - pi/2`), not a renderer branch.
pub const ConicGradient = struct {
    center: geometry.PointF,
    start_angle_radians: f32 = 0,
    stops: []const GradientStop = &.{},
    spread: GradientSpread = .pad,
    interpolation: GradientInterpolation = .srgb_linear,
};

/// One tensor-product bicubic mesh patch. Control points are row-major from
/// top-left (`points[0]`) to bottom-right (`points[15]`); colors name the four
/// corners in clockwise order. Adjacent patches should share their edge
/// control points and corner colors for a seamless mesh.
pub const MeshPatch = struct {
    points: [16]geometry.PointF,
    colors: [4]Color,
};

/// A two-dimensional gradient made from authored bicubic patches. Patch order
/// is deterministic: later patches win where malformed input overlaps. Unlike
/// linear/radial/conic gradients, a mesh has no one-dimensional spread axis.
pub const MeshGradient = struct {
    patches: []const MeshPatch = &.{},
    interpolation: GradientInterpolation = .srgb_linear,
};

pub const Fill = union(enum) {
    color: Color,
    linear_gradient: LinearGradient,
    radial_gradient: RadialGradient,
    conic_gradient: ConicGradient,
    mesh_gradient: MeshGradient,
};

pub const Stroke = struct {
    fill: Fill,
    width: f32 = 1,
};

pub const Clip = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    presentation_layer: PresentationLayer = .retained,
};

pub const FillRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    fill: Fill,
};

pub const StrokeRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    stroke: Stroke,
};

pub const FillRoundedRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius,
    fill: Fill,
};

pub const Line = struct {
    id: ObjectId = 0,
    from: geometry.PointF,
    to: geometry.PointF,
    stroke: Stroke,
};

pub const PathVerb = enum {
    move_to,
    line_to,
    quad_to,
    cubic_to,
    close,
};

pub const PathElement = struct {
    verb: PathVerb,
    points: [3]geometry.PointF = [_]geometry.PointF{geometry.PointF.zero()} ** 3,
};

pub const FillPath = struct {
    id: ObjectId = 0,
    elements: []const PathElement = &.{},
    fill: Fill,
};

/// Stroke end-cap shape for open subpaths. `butt` ends the stroke
/// exactly at the endpoint (the SVG default and what the packet hosts
/// draw when no cap is specified); `round` extends it with a
/// half-stroke-width semicircle — the stroke-icon dialect and the house
/// spinner arc are authored for round caps. Closed subpaths have no
/// ends, so the cap never affects them.
pub const LineCap = enum {
    butt,
    round,
};

pub const StrokePath = struct {
    id: ObjectId = 0,
    elements: []const PathElement = &.{},
    stroke: Stroke,
    /// End-cap shape for the path's open subpaths. Lives on the command
    /// (not on `Stroke`) because caps are a property of path stroking:
    /// rect strokes are closed contours and `draw_line` keeps its
    /// historical semantics, so a cap field there would be ignored.
    cap: LineCap = .butt,
};

pub const ImageFit = enum {
    stretch,
    contain,
    cover,
};

pub const ImageSampling = enum {
    nearest,
    linear,
};

pub const DrawImage = struct {
    id: ObjectId = 0,
    image_id: ImageId,
    src: ?geometry.RectF = null,
    dst: geometry.RectF,
    opacity: f32 = 1,
    fit: ImageFit = .stretch,
    sampling: ImageSampling = .linear,
    /// Repeat the selected source rect at its native logical-pixel size
    /// from the destination origin. When true, `fit` is ignored.
    tile: bool = false,
    /// Rounded-corner mask in destination space: pixels outside the
    /// rounded `dst` rect are not drawn (the avatar circle clip). Zero —
    /// the default — keeps the plain rectangular draw. Carried on the
    /// draw itself because the render plan flattens clip stacks to
    /// rectangles, which would drop a rounded clip's corners.
    radius: Radius = .{},
};

pub const Shadow = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    offset: geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    color: Color,
    /// Draw inside `rect` instead of casting outside it.
    inset: bool = false,
};

pub const Blur = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: f32 = 0,
};

pub fn strokeBounds(rect: geometry.RectF, width: f32) geometry.RectF {
    return rect.normalized().inflate(geometry.InsetsF.all(nonNegative(width) * 0.5));
}

pub fn shadowBounds(value: Shadow) geometry.RectF {
    if (value.inset) return value.rect.normalized();
    const spread = nonNegative(@abs(value.spread));
    const blur_radius = nonNegative(value.blur);
    return value.rect
        .normalized()
        .translate(value.offset)
        .inflate(geometry.InsetsF.all(spread + blur_radius));
}

pub fn pathBounds(elements: []const PathElement) ?geometry.RectF {
    var has_point = false;
    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    for (elements) |element| {
        const point_count: usize = switch (element.verb) {
            .move_to, .line_to => 1,
            .quad_to => 2,
            .cubic_to => 3,
            .close => 0,
        };
        for (element.points[0..point_count]) |point| {
            if (!has_point) {
                has_point = true;
                min_x = point.x;
                min_y = point.y;
                max_x = point.x;
                max_y = point.y;
            } else {
                min_x = @min(min_x, point.x);
                min_y = @min(min_y, point.y);
                max_x = @max(max_x, point.x);
                max_y = @max(max_y, point.y);
            }
        }
    }
    if (!has_point) return null;
    return geometry.RectF.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn boundsFromPoints(points: []const geometry.PointF) ?geometry.RectF {
    if (points.len == 0) return null;
    var min_x = points[0].x;
    var min_y = points[0].y;
    var max_x = points[0].x;
    var max_y = points[0].y;
    for (points[1..]) |point| {
        min_x = @min(min_x, point.x);
        min_y = @min(min_y, point.y);
        max_x = @max(max_x, point.x);
        max_y = @max(max_y, point.y);
    }
    return geometry.RectF.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
