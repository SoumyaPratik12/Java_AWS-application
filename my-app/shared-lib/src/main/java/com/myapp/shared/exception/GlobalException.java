package com.myapp.shared.exception;

public class GlobalException extends RuntimeException {

    private final int statusCode;
    private final String errorCode;

    public GlobalException(String message) {
        super(message);
        this.statusCode = 500;
        this.errorCode = "INTERNAL_ERROR";
    }

    public GlobalException(String message, int statusCode, String errorCode) {
        super(message);
        this.statusCode = statusCode;
        this.errorCode = errorCode;
    }

    public GlobalException(String message, Throwable cause) {
        super(message, cause);
        this.statusCode = 500;
        this.errorCode = "INTERNAL_ERROR";
    }

    public int getStatusCode() { return statusCode; }
    public String getErrorCode() { return errorCode; }
}
