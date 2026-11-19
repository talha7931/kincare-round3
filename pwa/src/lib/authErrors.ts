export type AuthMessageKind = "error" | "info" | "success";

export function validateRegistration(
  email: string,
  password: string,
  displayName: string,
): string | null {
  const normalizedEmail = email.trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail)) {
    return "Enter a valid email address.";
  }
  if (displayName.trim().length < 2) {
    return "Enter a display name.";
  }
  if (password.length < 8) {
    return "Password must contain at least 8 characters.";
  }
  if (!/[A-Za-z]/.test(password) || !/[0-9]/.test(password)) {
    return "Password must contain both letters and numbers.";
  }
  return null;
}

export function canStartAuthRequest(requestInFlight: boolean): boolean {
  return !requestInFlight;
}

export function canResendConfirmation(
  cooldownSeconds: number,
  requestInFlight: boolean,
  pendingEmail: string,
): boolean {
  return (
    cooldownSeconds <= 0 && !requestInFlight && pendingEmail.trim().length > 0
  );
}

export function validateInternationalPhone(phone: string): string | null {
  if (!/^\+[1-9]\d{7,14}$/.test(phone.trim())) {
    return "Enter an international phone number beginning with + and the country code.";
  }
  return null;
}

export function validateTestOtp(otp: string): string | null {
  if (!/^\d{6}$/.test(otp.trim())) {
    return "Enter the 6-digit test OTP.";
  }
  return null;
}

export function validateLogin(email: string, password: string): string | null {
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) {
    return "Enter a valid email address.";
  }
  if (!password) return "Enter your password.";
  return null;
}

export function isUnconfirmedEmailError(error: unknown): boolean {
  const authError = error as { message?: string; code?: string };
  const raw = (authError.message ?? "").toLowerCase();
  const code = (authError.code ?? "").toLowerCase();
  return (
    code === "email_not_confirmed" ||
    raw.includes("email not confirmed") ||
    raw.includes("email address not confirmed")
  );
}

export type ConfirmationCallbackResult =
  | { kind: "none" }
  | { kind: "code"; code: string }
  | { kind: "implicit-success" }
  | { kind: "failure"; message: string };

export function parseConfirmationCallback(
  url: string,
): ConfirmationCallbackResult {
  const parsed = new URL(url);
  const searchError =
    parsed.searchParams.get("error_description") ??
    parsed.searchParams.get("error");
  const hash = new URLSearchParams(parsed.hash.replace(/^#/, ""));
  const hashError = hash.get("error_description") ?? hash.get("error");

  if (searchError || hashError) {
    return {
      kind: "failure",
      message: (
        searchError ??
        hashError ??
        "Email confirmation failed."
      ).replaceAll("+", " "),
    };
  }

  const code = parsed.searchParams.get("code");
  if (code) return { kind: "code", code };

  if (parsed.hash.includes("access_token="))
    return { kind: "implicit-success" };

  if (parsed.pathname === "/confirm-email")
    return {
      kind: "failure",
      message: "No confirmation token was found in this link.",
    };

  return { kind: "none" };
}

export function getAuthErrorMessage(error: unknown): {
  kind: AuthMessageKind;
  message: string;
} {
  const authError = error as {
    message?: string;
    code?: string;
    status?: number;
  };
  const raw = (authError.message ?? "").toLowerCase();
  const code = (authError.code ?? "").toLowerCase();

  if (
    authError.status === 429 ||
    code.includes("rate_limit") ||
    code === "over_request_rate_limit" ||
    raw.includes("email rate limit exceeded") ||
    raw.includes("too many requests")
  ) {
    return {
      kind: "error",
      message:
        "Too many verification requests. Please wait before trying again.",
    };
  }

  if (
    code.includes("user_already_exists") ||
    raw.includes("user already registered") ||
    raw.includes("already been registered") ||
    raw.includes("email address has already been registered")
  ) {
    return {
      kind: "error",
      message:
        "An account already exists for this email. Sign in or use “Resend confirmation” if email verification is pending.",
    };
  }

  if (
    code === "email_not_confirmed" ||
    raw.includes("email not confirmed") ||
    raw.includes("email address not confirmed")
  ) {
    return {
      kind: "error",
      message:
        "Verify your email address before signing in. Open the confirmation email or resend it below.",
    };
  }

  if (raw.includes("invalid login credentials")) {
    return {
      kind: "error",
      message: "The email or password is incorrect.",
    };
  }

  if (raw.includes("invalid email")) {
    return {
      kind: "error",
      message: "Enter a valid email address.",
    };
  }

  if (authError.status && authError.status >= 500) {
    return {
      kind: "error",
      message:
        "KinCare could not reach Supabase right now. Check your connection and try again.",
    };
  }

  return {
    kind: "error",
    message: authError.message
      ? authError.message
      : "Authentication failed. Please try again.",
  };
}
