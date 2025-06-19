const std = @import("std");

pub const HttpError = error{
BadRequest,
Unauthorized,
Forbidden,
NotFound,
MethodNotAllowed,
RequestTimeout,
PayloadTooLarge,
InternalServerError,
HTTPVersionNotSupported
};

pub fn errorToStatusCode(err: HttpError) u16 {
    return switch (err) {
        HttpError.BadRequest => 400,
        HttpError.Unauthorized => 401,
        HttpError.Forbidden => 403,
        HttpError.NotFound => 404,
        HttpError.MethodNotAllowed => 405,
        HttpError.RequestTimeout => 408,
        HttpError.PayloadTooLarge => 413,
        HttpError.InternalServerError => 500,
        HttpError.HTTPVersionNotSupported => 505
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
        500 => "Internal Server Error",
        505 => "HTTP Version Not Supported",
        else => null,
    };
}

pub fn toHttpError(err: anyerror, default_err: HttpError) HttpError {
    for (std.meta.fields(HttpError)) |http_error| {
        if (std.mem.eql(u8, http_error.name, @errorName(err))) {
            return @errorCast(err);
        }
    }
    return default_err;
}