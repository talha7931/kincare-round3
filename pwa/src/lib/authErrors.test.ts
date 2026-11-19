import { describe, expect, it } from "vitest";
import {
  canResendConfirmation,
  canStartAuthRequest,
  getAuthErrorMessage,
  isUnconfirmedEmailError,
  parseConfirmationCallback,
  validateInternationalPhone,
  validateTestOtp,
  validateLogin,
  validateRegistration,
} from "./authErrors";

describe("PWA caregiver auth validation", () => {
  it("rejects invalid registration email and weak passwords", () => {
    expect(validateRegistration("bad-email", "12345678", "Talha")).toBe(
      "Enter a valid email address.",
    );
    expect(validateRegistration("talha@example.com", "abcdefgh", "Talha")).toBe(
      "Password must contain both letters and numbers.",
    );
  });

  it("accepts valid registration and login input", () => {
    expect(
      validateRegistration("talha@example.com", "KinCare2026", "Talha"),
    ).toBeNull();
    expect(validateLogin("talha@example.com", "KinCare2026")).toBeNull();
  });

  it("rejects missing login credentials", () => {
    expect(validateLogin("", "")).toBe("Enter a valid email address.");
  });
});

describe("PWA prototype phone authentication", () => {
  it("accepts international phone numbers only", () => {
    expect(validateInternationalPhone("+919876543210")).toBeNull();
    expect(validateInternationalPhone("9876543210")).toContain("country code");
  });

  it("requires a 6-digit test OTP", () => {
    expect(validateTestOtp("123456")).toBeNull();
    expect(validateTestOtp("123")).toBe("Enter the 6-digit test OTP.");
  });
});

describe("PWA duplicate-submit and resend guards", () => {
  it("blocks duplicate auth submissions while one request is in flight", () => {
    expect(canStartAuthRequest(false)).toBe(true);
    expect(canStartAuthRequest(true)).toBe(false);
  });

  it("blocks resend during cooldown or while another request is active", () => {
    expect(canResendConfirmation(60, false, "talha@example.com")).toBe(false);
    expect(canResendConfirmation(0, true, "talha@example.com")).toBe(false);
    expect(canResendConfirmation(0, false, "")).toBe(false);
    expect(canResendConfirmation(0, false, "talha@example.com")).toBe(true);
  });
});

describe("PWA Supabase auth errors", () => {
  it("maps email rate limits clearly", () => {
    expect(
      getAuthErrorMessage({ status: 429, message: "email rate limit exceeded" })
        .message,
    ).toBe("Too many verification requests. Please wait before trying again.");
  });

  it("maps duplicate accounts separately", () => {
    expect(
      getAuthErrorMessage({
        code: "user_already_exists",
        message: "User already registered",
      }).message,
    ).toContain("An account already exists");
  });

  it("maps unconfirmed email login gracefully", () => {
    expect(
      isUnconfirmedEmailError({
        code: "email_not_confirmed",
        message: "Email not confirmed",
      }),
    ).toBe(true);
    expect(
      getAuthErrorMessage({
        code: "email_not_confirmed",
        message: "Email not confirmed",
      }).message,
    ).toContain("Verify your email address");
  });
});

describe("PWA confirmation callback", () => {
  it("parses a PKCE confirmation code", () => {
    expect(
      parseConfirmationCallback(
        "https://app.example/confirm-email?code=abc123",
      ),
    ).toEqual({ kind: "code", code: "abc123" });
  });

  it("parses a callback failure", () => {
    expect(
      parseConfirmationCallback(
        "https://app.example/confirm-email?error=access_denied&error_description=Email+link+expired",
      ),
    ).toEqual({ kind: "failure", message: "Email link expired" });
  });

  it("parses an implicit access-token success", () => {
    expect(
      parseConfirmationCallback(
        "https://app.example/confirm-email#access_token=test&type=signup",
      ),
    ).toEqual({ kind: "implicit-success" });
  });

  it("does not treat an unrelated URL as a confirmation callback", () => {
    expect(parseConfirmationCallback("https://app.example/")).toEqual({
      kind: "none",
    });
  });
});
