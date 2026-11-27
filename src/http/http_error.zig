const std = @import("std");

pub const HttpError = error{
    BadRequest,
    Unauthorized,
    PaymentRequired,
    Forbidden,
    NotFound,
    MethodNotAllowed,
    NotAcceptable,
    ProxyAuthenticationRequired,
    RequestTimeout,
    Conflict,
    Gone,
    LengthRequired,
    PreconditionFailed,
    PayloadTooLarge,
    UriTooLong,
    UnsupportedMediaType,
    RangeNotSatisfiable,
    ExpectationFailed,
    MisdirectedRequest,
    UnprocessableContent,
    Locked,
    FailedDependency,
    TooEarly,
    UpgradeRequired,
    PreconditionRequired,
    TooManyRequests,
    RequestHeaderFieldsTooLarge,
    UnavailableForLegalReasons,
    InternalServerError,
    NotImplemented,
    BadGateway,
    ServiceUnavailable,
    GatewayTimeout,
    HttpVersionNotSupported,
    VariantAlsoNegotiates,
    InsufficientStorage,
    LoopDetected,
    NotExtended,
    NetworkAuthenticationRequired,
};

pub fn errorToStatusCode(err: HttpError) u16 {
    return switch (err) {
        HttpError.BadRequest => 400,
        HttpError.Unauthorized => 401,
        HttpError.PaymentRequired => 402,
        HttpError.Forbidden => 403,
        HttpError.NotFound => 404,
        HttpError.MethodNotAllowed => 405,
        HttpError.NotAcceptable => 406,
        HttpError.ProxyAuthenticationRequired => 407,
        HttpError.RequestTimeout => 408,
        HttpError.Conflict => 409,
        HttpError.Gone => 410,
        HttpError.LengthRequired => 411,
        HttpError.PreconditionFailed => 412,
        HttpError.PayloadTooLarge => 413,
        HttpError.UriTooLong => 414,
        HttpError.UnsupportedMediaType => 415,
        HttpError.RangeNotSatisfiable => 416,
        HttpError.ExpectationFailed => 417,
        HttpError.MisdirectedRequest => 421,
        HttpError.UnprocessableContent => 422,
        HttpError.Locked => 423,
        HttpError.FailedDependency => 424,
        HttpError.TooEarly => 425,
        HttpError.UpgradeRequired => 426,
        HttpError.PreconditionRequired => 428,
        HttpError.TooManyRequests => 429,
        HttpError.RequestHeaderFieldsTooLarge => 431,
        HttpError.UnavailableForLegalReasons => 451,
        HttpError.InternalServerError => 500,
        HttpError.NotImplemented => 501,
        HttpError.BadGateway => 502,
        HttpError.ServiceUnavailable => 503,
        HttpError.GatewayTimeout => 504,
        HttpError.HttpVersionNotSupported => 505,
        HttpError.VariantAlsoNegotiates => 506,
        HttpError.InsufficientStorage => 507,
        HttpError.LoopDetected => 508,
        HttpError.NotExtended => 510,
        HttpError.NetworkAuthenticationRequired => 511,
    };
}

pub fn statusCodeToMessage(code: u16) ?[]const u8 {
    return switch (code) {
        100 => "Continue",
        101 => "Switching Protocols",
        102 => "Processing",
        103 => "Early Hints",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        207 => "Multi-Status",
        208 => "Already Reported",
        226 => "IM Used",
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        305 => "Use Proxy",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        421 => "Misdirected Request",
        422 => "Unprocessable Content",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        506 => "Variant Also Negotiates",
        507 => "Insufficient Storage",
        508 => "Loop Detected",
        510 => "Not Extended",
        511 => "Network Authentication Required",
        else => null,
    };
}

pub fn toHttpError(err: anyerror, default_err: HttpError) HttpError {
    // Compares error values directly (no string comparison): the loop is unrolled at
    // compile time over the members of HttpError.
    inline for (@typeInfo(HttpError).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) {
            return @field(HttpError, name);
        }
    }
    return default_err;
}

test "every HttpError maps to a distinct 4xx or 5xx code with a reason phrase" {
    var seen: std.StaticBitSet(600) = .empty;
    inline for (@typeInfo(HttpError).error_set.error_names.?) |name| {
        const code = errorToStatusCode(@field(HttpError, name));
        try std.testing.expect(code >= 400 and code < 600);
        try std.testing.expect(!seen.isSet(code));
        seen.set(code);
        try std.testing.expect(statusCodeToMessage(code) != null);
    }
}

test "toHttpError maps matching errors and falls back otherwise" {
    try std.testing.expectEqual(HttpError.TooManyRequests, toHttpError(error.TooManyRequests, HttpError.InternalServerError));
    try std.testing.expectEqual(HttpError.InternalServerError, toHttpError(error.OutOfMemory, HttpError.InternalServerError));
}
