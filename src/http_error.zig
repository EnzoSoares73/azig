const std = @import("std");

pub const HttpError = error{ BadRequest, Unauthorized, Forbidden, NotFound, MethodNotAllowed, RequestTimeout, PayloadTooLarge, RequestHeaderFieldsTooLarge, InternalServerError, HttpVersionNotSupported };

pub fn errorToStatusCode(err: HttpError) u16 {
    return switch (err) {
        HttpError.BadRequest => 400,
        HttpError.Unauthorized => 401,
        HttpError.Forbidden => 403,
        HttpError.NotFound => 404,
        HttpError.MethodNotAllowed => 405,
        HttpError.RequestTimeout => 408,
        HttpError.PayloadTooLarge => 413,
        HttpError.RequestHeaderFieldsTooLarge => 431,
        HttpError.InternalServerError => 500,
        HttpError.HttpVersionNotSupported => 505,
    };
}

pub fn statusCodeToMessage(code: u16) ?[]const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Payload too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        505 => "HTTP Version Not Supported",
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
