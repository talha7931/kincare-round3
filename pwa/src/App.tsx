import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import type { User } from "@supabase/supabase-js";
import { supabase } from "./lib/supabase";
import { MemoryDecks } from "./components/MemoryDecks";
import { SeniorMemoryViewer } from "./components/SeniorMemoryViewer";
import { CognitiveGames } from "./components/CognitiveGames";
import { CaregiverActivityHistory } from "./components/CaregiverActivityHistory";
import {
  cognitiveGameActivityKeys,
  isCognitiveGameActivityKey,
} from "./lib/cognitiveGames";
import {
  canResendConfirmation,
  canStartAuthRequest,
  getAuthErrorMessage,
  isUnconfirmedEmailError,
  parseConfirmationCallback,
  validateInternationalPhone,
  validateLogin,
  validateRegistration,
  validateTestOtp,
} from "./lib/authErrors";
import "./App.css";

type ElderlyProfile = {
  id: string;
  display_name: string;
  preferred_language: string;
};

type SeniorActivityKey =
  | "memory"
  | typeof cognitiveGameActivityKeys.oddOneOut
  | typeof cognitiveGameActivityKeys.sorting;

type SeniorActivity = {
  key: SeniorActivityKey;
  name: string;
  description: string;
  availability: string;
};

/**
 * The activity board exposes the shared Phase 2 and Phase 3 journeys.
 */
const SENIOR_ACTIVITIES: readonly SeniorActivity[] = [
  {
    key: "memory",
    name: "Memory Decks",
    description: "Look at familiar photographs and share a memory.",
    availability: "Available after cards are added",
  },
  {
    key: cognitiveGameActivityKeys.oddOneOut,
    name: "Odd One Out",
    description: "Choose the item that is different.",
    availability: "Ready to play",
  },
  {
    key: cognitiveGameActivityKeys.sorting,
    name: "Everyday Object Sorting",
    description: "Place familiar objects in the right group.",
    availability: "Ready to play",
  },
];

const LANGUAGE_LABELS: Record<string, string> = {
  en: "English",
  hi: "Hindi",
  mr: "Marathi",
};

/** Stored codes are never shown raw; unknown codes fall back to upper case. */
function languageLabel(code: string) {
  return LANGUAGE_LABELS[code] ?? code.toUpperCase();
}

function profileInitial(displayName: string) {
  const trimmed = displayName.trim();
  return trimmed ? trimmed.charAt(0).toUpperCase() : "\u2014";
}

function App() {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [mode, setMode] = useState<"login" | "register">("login");
  const [authMethod, setAuthMethod] = useState<"email" | "phone">("email");
  const [phoneNumber, setPhoneNumber] = useState("");
  const [phoneOtp, setPhoneOtp] = useState("");
  const [phoneOtpSent, setPhoneOtpSent] = useState(false);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [caregiverName, setCaregiverName] = useState("");
  const [profiles, setProfiles] = useState<ElderlyProfile[]>([]);
  const [profilesLoading, setProfilesLoading] = useState(false);
  const [profileMutationLoading, setProfileMutationLoading] = useState(false);
  const [selectedProfile, setSelectedProfile] = useState<ElderlyProfile | null>(
    null,
  );
  const [profileName, setProfileName] = useState("");
  const [profileLanguage, setProfileLanguage] = useState("en");
  const [appMode, setAppMode] = useState<"caregiver" | "elderly">("caregiver");
  const [openActivity, setOpenActivity] = useState<SeniorActivityKey | null>(
    null,
  );
  const [caregiverSection, setCaregiverSection] = useState<
    "overview" | "profiles" | "memory" | "activity" | "reports" | "wellbeing"
  >("overview");
  const [error, setError] = useState("");
  const [authNotice, setAuthNotice] = useState("");
  const [authSubmitting, setAuthSubmitting] = useState(false);
  const [signupPendingEmail, setSignupPendingEmail] = useState("");
  const [resendCooldownSeconds, setResendCooldownSeconds] = useState(0);
  const authRequestInFlight = useRef(false);

  useEffect(() => {
    const callback = parseConfirmationCallback(window.location.href);

    if (callback.kind === "code") {
      supabase.auth
        .exchangeCodeForSession(callback.code)
        .then(({ data, error: callbackError }) => {
          if (callbackError) {
            setError(`Email confirmation failed: ${callbackError.message}`);
            setAuthNotice("");
            window.history.replaceState({}, "", "/");
            return;
          }

          if (data.session?.user) {
            setAuthNotice("Email verified successfully. Sign in to continue.");
            setError("");
            void supabase.auth.signOut();
            window.history.replaceState({}, "", "/");
          }
        })
        .catch(() => {
          setError(
            "Email confirmation could not be completed. Please try again or resend the confirmation email.",
          );
          window.history.replaceState({}, "", "/");
        });
    } else if (callback.kind === "implicit-success") {
      supabase.auth.getSession().then(({ data }) => {
        if (data.session?.user) {
          setAuthNotice("Email verified successfully. Sign in to continue.");
          setError("");
          void supabase.auth.signOut();
        } else {
          setError(
            "Email confirmation could not be completed. Please try again or resend the confirmation email.",
          );
        }
        window.history.replaceState({}, "", "/");
      });
    } else if (callback.kind === "failure") {
      setError(`Email confirmation failed: ${callback.message}`);
      setAuthNotice("");
      window.history.replaceState({}, "", "/");
    } else {
      supabase.auth
        .getSession()
        .then(({ data }) => setUser(data.session?.user ?? null));
    }

    const { data } = supabase.auth.onAuthStateChange((_event, session) => {
      setUser(session?.user ?? null);
    });
    setLoading(false);
    return () => data.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (resendCooldownSeconds <= 0) return;
    const timer = window.setTimeout(() => {
      setResendCooldownSeconds((seconds) => Math.max(0, seconds - 1));
    }, 1000);
    return () => window.clearTimeout(timer);
  }, [resendCooldownSeconds]);

  useEffect(() => {
    if (user) void loadCaregiverData();
  }, [user]);

  async function ensureCaregiverProfile() {
    if (!user) return;
    const { data, error: caregiverError } = await supabase
      .from("caregivers")
      .select("display_name")
      .eq("id", user.id)
      .maybeSingle();

    if (caregiverError) throw caregiverError;
    if (data) {
      setCaregiverName(data.display_name ?? "");
      return;
    }

    const fallbackName = user.user_metadata?.display_name ?? "";
    const { error: insertError } = await supabase
      .from("caregivers")
      .insert({ id: user.id, display_name: fallbackName || null });
    if (insertError) throw insertError;
    setCaregiverName(fallbackName);
  }

  async function loadProfiles() {
    setProfilesLoading(true);
    try {
      const { data, error: profilesError } = await supabase
        .from("elderly_profiles")
        .select("id, display_name, preferred_language")
        .order("created_at", { ascending: true });

      if (profilesError) throw profilesError;
      setProfiles(data ?? []);
    } finally {
      setProfilesLoading(false);
    }
  }

  async function loadCaregiverData() {
    setError("");
    try {
      await ensureCaregiverProfile();
      await loadProfiles();
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : "Unable to load account data",
      );
    }
  }

  async function submitAuth(event: FormEvent) {
    event.preventDefault();
    if (!canStartAuthRequest(authRequestInFlight.current)) return;

    setError("");
    setAuthNotice("");

    const validationError =
      mode === "register"
        ? validateRegistration(email, password, displayName)
        : validateLogin(email, password);
    if (validationError) {
      setError(validationError);
      return;
    }

    authRequestInFlight.current = true;
    setAuthSubmitting(true);
    try {
      if (mode === "register") {
        const { data, error: signUpError } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: {
            data: { display_name: displayName.trim() },
            emailRedirectTo: `${window.location.origin}/confirm-email`,
          },
        });
        if (signUpError) throw signUpError;

        if (data.session) {
          setAuthNotice("Account created and signed in.");
        } else {
          const normalizedEmail = email.trim();
          setSignupPendingEmail(normalizedEmail);
          setAuthNotice(
            "Account created. Verify your email before signing in. Open the confirmation email sent to you.",
          );
        }
      } else {
        const { error: signInError } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        });
        if (signInError) throw signInError;
      }
    } catch (caught) {
      const authMessage = getAuthErrorMessage(caught);
      if (isUnconfirmedEmailError(caught)) {
        setSignupPendingEmail(email.trim());
      }
      setError(authMessage.message);
    } finally {
      authRequestInFlight.current = false;
      setAuthSubmitting(false);
    }
  }

  async function resendConfirmation() {
    if (
      !canResendConfirmation(
        resendCooldownSeconds,
        authRequestInFlight.current,
        signupPendingEmail,
      )
    )
      return;

    setError("");
    setAuthNotice("");
    authRequestInFlight.current = true;
    setAuthSubmitting(true);
    try {
      const { error: resendError } = await supabase.auth.resend({
        type: "signup",
        email: signupPendingEmail,
        options: {
          emailRedirectTo: `${window.location.origin}/confirm-email`,
        },
      });
      if (resendError) throw resendError;

      setResendCooldownSeconds(60);
      setAuthNotice(
        "A new confirmation email was requested. Please wait for it to arrive before requesting another.",
      );
    } catch (caught) {
      const authMessage = getAuthErrorMessage(caught);
      setError(authMessage.message);
      if (authMessage.message.startsWith("Too many verification requests")) {
        setResendCooldownSeconds(60);
      }
    } finally {
      authRequestInFlight.current = false;
      setAuthSubmitting(false);
    }
  }

  async function submitPhone(event: FormEvent) {
    event.preventDefault();
    if (!canStartAuthRequest(authRequestInFlight.current)) return;

    setError("");
    setAuthNotice("");
    const normalizedPhone = phoneNumber.trim();
    const phoneValidationError = validateInternationalPhone(normalizedPhone);
    if (phoneValidationError) {
      setError(phoneValidationError);
      return;
    }

    authRequestInFlight.current = true;
    setAuthSubmitting(true);
    try {
      if (!phoneOtpSent) {
        const { error: otpError } = await supabase.auth.signInWithOtp({
          phone: normalizedPhone,
        });
        if (otpError) throw otpError;
        setPhoneOtpSent(true);
        setAuthNotice(
          "Enter the fixed test OTP configured for this test phone number in Supabase.",
        );
      } else {
        const otpValidationError = validateTestOtp(phoneOtp);
        if (otpValidationError) {
          setError(otpValidationError);
          return;
        }
        const { error: verifyError } = await supabase.auth.verifyOtp({
          phone: normalizedPhone,
          token: phoneOtp.trim(),
          type: "sms",
        });
        if (verifyError) throw verifyError;
        setAuthNotice("Phone verification complete. Signing in...");
      }
    } catch (caught) {
      setError(getAuthErrorMessage(caught).message);
    } finally {
      authRequestInFlight.current = false;
      setAuthSubmitting(false);
    }
  }

  async function signOut() {
    setError("");
    const { error: signOutError } = await supabase.auth.signOut();
    if (signOutError) setError(signOutError.message);
  }

  async function saveCaregiverName(event: FormEvent) {
    event.preventDefault();
    if (!user) return;
    setError("");
    const { error: updateError } = await supabase
      .from("caregivers")
      .update({ display_name: caregiverName.trim() || null })
      .eq("id", user.id);
    if (updateError) setError(updateError.message);
  }

  async function createProfile(event: FormEvent) {
    event.preventDefault();
    if (!user) return;
    setError("");
    setProfileMutationLoading(true);
    try {
      const { error: insertError } = await supabase
        .from("elderly_profiles")
        .insert({
          caregiver_id: user.id,
          display_name: profileName.trim(),
          preferred_language: profileLanguage,
        });

      if (insertError) throw insertError;
      setProfileName("");
      setProfileLanguage("en");
      await loadProfiles();
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : "Unable to create the profile. Check your connection and try again.",
      );
    } finally {
      setProfileMutationLoading(false);
    }
  }

  async function updateProfile(event: FormEvent) {
    event.preventDefault();
    if (!selectedProfile) return;
    setError("");
    setProfileMutationLoading(true);
    try {
      const { error: updateError } = await supabase
        .from("elderly_profiles")
        .update({
          display_name: selectedProfile.display_name.trim(),
          preferred_language: selectedProfile.preferred_language,
        })
        .eq("id", selectedProfile.id);

      if (updateError) throw updateError;
      await loadProfiles();
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : "Unable to save profile changes. Check your connection and try again.",
      );
    } finally {
      setProfileMutationLoading(false);
    }
  }

  async function deleteProfile(profile: ElderlyProfile) {
    if (!window.confirm(`Delete ${profile.display_name}?`)) return;
    setError("");
    setProfileMutationLoading(true);
    try {
      const { error: deleteError } = await supabase
        .from("elderly_profiles")
        .delete()
        .eq("id", profile.id);

      if (deleteError) throw deleteError;
      setProfiles((current) =>
        current.filter((item) => item.id !== profile.id),
      );
      if (selectedProfile?.id === profile.id) setSelectedProfile(null);
      await loadProfiles();
    } catch (caught) {
      const deleteMessage =
        caught instanceof Error ? caught.message : "Unable to delete profile.";
      setError(
        deleteMessage.toLowerCase().includes("foreign key") ||
          (caught as { code?: string })?.code === "23503"
          ? "This profile cannot be deleted because it has dependent records. Keep the profile and remove dependent records separately."
          : deleteMessage,
      );
    } finally {
      setProfileMutationLoading(false);
    }
  }

  if (loading) return <main className="loading">Loading KinCare...</main>;

  if (!user) {
    return (
      <main className="auth-shell">
        <section className="auth-panel" aria-labelledby="auth-title">
          <div className="auth-brand">
            <span className="brand-mark" aria-hidden="true">
              K
            </span>
            <span className="auth-brand-name">KinCare</span>
          </div>
          <h1 id="auth-title">
            {authMethod === "phone"
              ? "Caregiver phone sign in"
              : mode === "login"
                ? "Caregiver sign in"
                : "Create caregiver account"}
          </h1>
          <div
            className="auth-method-choice"
            aria-label="Authentication method"
            role="group"
          >
            <button
              type="button"
              className={authMethod === "email" ? "active" : ""}
              aria-pressed={authMethod === "email"}
              onClick={() => {
                setAuthMethod("email");
                setError("");
                setAuthNotice("");
              }}
            >
              Continue with Email
            </button>
            <button
              type="button"
              className={authMethod === "phone" ? "active" : ""}
              aria-pressed={authMethod === "phone"}
              onClick={() => {
                setAuthMethod("phone");
                setError("");
                setAuthNotice("");
              }}
            >
              Continue with Phone
            </button>
          </div>

          {authMethod === "phone" ? (
            <form onSubmit={submitPhone} className="auth-form">
              <div className="prototype-auth-note">
                Prototype test authentication uses a configured Supabase test
                phone number and fixed test OTP. No SMS is sent.
              </div>
              <label className="field">
                International phone number
                <input
                  type="tel"
                  inputMode="tel"
                  placeholder="+91..."
                  value={phoneNumber}
                  onChange={(event) => setPhoneNumber(event.target.value)}
                  required
                />
              </label>
              {phoneOtpSent && (
                <label className="field">
                  6-digit test OTP
                  <input
                    inputMode="numeric"
                    maxLength={6}
                    value={phoneOtp}
                    onChange={(event) =>
                      setPhoneOtp(event.target.value.replace(/\D/g, ""))
                    }
                    required
                  />
                </label>
              )}
              {authNotice && (
                <p className="auth-success" role="status">
                  {authNotice}
                </p>
              )}
              {error && (
                <p className="error" role="alert">
                  {error}
                </p>
              )}
              <button
                className="btn btn-primary auth-submit"
                type="submit"
                disabled={authSubmitting || !phoneNumber.trim()}
              >
                {authSubmitting
                  ? "Please wait..."
                  : phoneOtpSent
                    ? "Verify OTP"
                    : "Send test OTP"}
              </button>
            </form>
          ) : (
            <form onSubmit={submitAuth} className="auth-form">
              {mode === "register" && (
                <label className="field">
                  Display name
                  <input
                    value={displayName}
                    onChange={(event) => setDisplayName(event.target.value)}
                    required
                  />
                </label>
              )}
              <label className="field">
                Email
                <input
                  type="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  required
                />
              </label>
              <label className="field">
                Password
                <input
                  type="password"
                  minLength={8}
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  required
                />
              </label>
              {authNotice && (
                <p className="auth-success" role="status">
                  {authNotice}
                </p>
              )}
              {error && (
                <p className="error" role="alert">
                  {error}
                </p>
              )}
              <button
                className="btn btn-primary auth-submit"
                type="submit"
                disabled={authSubmitting}
              >
                {authSubmitting
                  ? "Please wait..."
                  : mode === "login"
                    ? "Sign in"
                    : "Register"}
              </button>
            </form>
          )}
          {authMethod === "email" && (
            <div className="auth-links">
              {signupPendingEmail && (
                <button
                  className="text-button"
                  type="button"
                  disabled={authSubmitting || resendCooldownSeconds > 0}
                  onClick={resendConfirmation}
                >
                  {resendCooldownSeconds > 0
                    ? `Resend confirmation in ${resendCooldownSeconds}s`
                    : "Resend confirmation email"}
                </button>
              )}
              <button
                className="text-button"
                type="button"
                onClick={() => {
                  setError("");
                  setAuthNotice("");
                  setSignupPendingEmail("");
                  setMode(mode === "login" ? "register" : "login");
                }}
              >
                {mode === "login" ? "Create an account" : "Back to sign in"}
              </button>
            </div>
          )}
        </section>
      </main>
    );
  }

  const sectionTitles = {
    overview: "Overview",
    profiles: "Elderly profiles",
    memory: "Memory Decks",
    activity: "Activity history",
    reports: "Doctor report",
    wellbeing: "Caregiver wellbeing",
  };

  if (appMode === "elderly") {
    const activeActivity =
      SENIOR_ACTIVITIES.find((activity) => activity.key === openActivity) ??
      null;

    return (
      <main className="senior-shell">
        <header className="senior-header">
          <button
            type="button"
            className="senior-home"
            onClick={() => setAppMode("caregiver")}
          >
            Caregiver mode
          </button>
          <div className="senior-heading">
            <p>KinCare</p>
            <h1>
              {selectedProfile
                ? `Hello, ${selectedProfile.display_name}`
                : "Choose a person"}
            </h1>
          </div>
          <button type="button" className="senior-signout" onClick={signOut}>
            Sign out
          </button>
        </header>

        {error && (
          <p className="senior-message senior-error" role="alert">
            {error}
          </p>
        )}

        {openActivity === "memory" && selectedProfile ? (
          <SeniorMemoryViewer
            profile={selectedProfile}
            onBack={() => setOpenActivity(null)}
            onHome={() => {
              setOpenActivity(null);
              setSelectedProfile(null);
            }}
          />
        ) : isCognitiveGameActivityKey(openActivity) && selectedProfile ? (
          <CognitiveGames
            key={`${selectedProfile.id}-${openActivity}`}
            profile={selectedProfile}
            game={openActivity}
            onBack={() => setOpenActivity(null)}
            onHome={() => {
              setOpenActivity(null);
              setSelectedProfile(null);
            }}
          />
        ) : openActivity ? (
          <section
            className="senior-content"
            aria-label="Activity availability"
          >
            <div className="senior-choice-heading senior-choice-heading--pair">
              <button
                type="button"
                className="senior-back"
                onClick={() => setOpenActivity(null)}
              >
                Back
              </button>
              <button
                type="button"
                className="senior-home"
                onClick={() => {
                  setOpenActivity(null);
                  setSelectedProfile(null);
                }}
              >
                Home
              </button>
            </div>
            <div className="senior-not-setup">
              <h2>{activeActivity?.name ?? "Activity"}</h2>
              <p>
                This activity is not ready yet. Ask your caregiver to set it up.
              </p>
            </div>
          </section>
        ) : !selectedProfile ? (
          <section className="senior-content" aria-labelledby="choose-person">
            <h2 id="choose-person">Who is using KinCare?</h2>
            {profiles.length === 0 ? (
              <div className="senior-empty">
                No elderly profiles are available. Ask the caregiver to add one.
              </div>
            ) : (
              <div className="senior-profile-grid">
                {profiles.map((profile) => (
                  <button
                    type="button"
                    className="senior-profile"
                    key={profile.id}
                    onClick={() => setSelectedProfile(profile)}
                  >
                    <span className="profile-initial" aria-hidden="true">
                      {profileInitial(profile.display_name)}
                    </span>
                    <strong>{profile.display_name}</strong>
                  </button>
                ))}
              </div>
            )}
          </section>
        ) : (
          <section className="senior-content" aria-label="Elderly activities">
            <div className="senior-choice-heading">
              <button
                type="button"
                className="senior-back"
                onClick={() => {
                  setOpenActivity(null);
                  setSelectedProfile(null);
                }}
              >
                Back
              </button>
              <h2>Choose an activity</h2>
              <button
                type="button"
                className="senior-home"
                onClick={() => {
                  setOpenActivity(null);
                  setSelectedProfile(null);
                }}
              >
                Home
              </button>
            </div>

            <div className="senior-activity-board">
              {SENIOR_ACTIVITIES.map((activity) => (
                <button
                  type="button"
                  className="senior-activity"
                  key={activity.key}
                  onClick={() => setOpenActivity(activity.key)}
                >
                  <span className="senior-activity-name">{activity.name}</span>
                  <span className="senior-activity-description">
                    {activity.description}
                  </span>
                  <span className="senior-activity-availability">
                    {activity.availability}
                  </span>
                </button>
              ))}
            </div>
          </section>
        )}
      </main>
    );
  }

  return (
    <main className="app-shell">
      <aside className="caregiver-sidebar">
        <div className="brand-block">
          <div className="brand-mark" aria-hidden="true">
            K
          </div>
          <div>
            <strong>KinCare</strong>
            <span>Caregiver space</span>
          </div>
        </div>

        <nav className="caregiver-nav" aria-label="Caregiver navigation">
          {(
            [
              ["overview", "Overview"],
              ["profiles", "Elderly profiles"],
              ["memory", "Memory Decks"],
              ["activity", "Activity history"],
              ["reports", "Doctor report"],
              ["wellbeing", "Wellbeing"],
            ] as const
          ).map(([section, label]) => (
            <button
              type="button"
              className={caregiverSection === section ? "active" : ""}
              aria-current={caregiverSection === section ? "page" : undefined}
              key={section}
              onClick={() => setCaregiverSection(section)}
            >
              {label}
            </button>
          ))}
        </nav>

        <div className="sidebar-actions">
          <button
            type="button"
            className="elderly-mode-button"
            onClick={() => setAppMode("elderly")}
          >
            Open elderly mode
          </button>
          <button type="button" className="signout-button" onClick={signOut}>
            Sign out
          </button>
        </div>
      </aside>

      <section className="caregiver-workspace">
        <header className="workspace-header">
          <h1>{sectionTitles[caregiverSection]}</h1>
          <div className="mode-switch" aria-label="Application mode">
            <button
              type="button"
              className="active"
              aria-pressed="true"
              onClick={() => setAppMode("caregiver")}
            >
              Caregiver
            </button>
            <button
              type="button"
              aria-pressed="false"
              onClick={() => setAppMode("elderly")}
            >
              Elderly
            </button>
          </div>
        </header>

        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}

        {caregiverSection === "overview" && (
          <section className="overview-layout">
            <div className="identity-surface">
              <span className="identity-initial" aria-hidden="true">
                {profileInitial(selectedProfile?.display_name ?? "")}
              </span>
              <div>
                <strong
                  className={`identity-name ${selectedProfile ? "" : "identity-name--empty"}`}
                >
                  {selectedProfile?.display_name ?? "None selected"}
                </strong>
                <p className="identity-language">
                  {selectedProfile
                    ? `Preferred language: ${languageLabel(selectedProfile.preferred_language)}`
                    : "Choose a person to see their language and activities."}
                </p>
              </div>
              <button
                type="button"
                className="btn btn-primary identity-action"
                onClick={() => setCaregiverSection("profiles")}
              >
                Choose profile
              </button>
            </div>

            <div className="support-column">
              <div className="support-row">
                <span className="support-label">Elderly profiles</span>
                <span className="support-value">{profiles.length}</span>
                <button
                  type="button"
                  className="btn btn-quiet"
                  onClick={() => setCaregiverSection("profiles")}
                >
                  Manage profiles
                </button>
              </div>
              <div className="support-row">
                <span className="support-label">Current mode</span>
                <span className="support-value">Caregiver</span>
                <button
                  type="button"
                  className="btn btn-quiet"
                  onClick={() => setAppMode("elderly")}
                >
                  Open senior view
                </button>
              </div>
              <div className="support-row">
                <h2>Participation history</h2>
                <p className="empty-state support-empty">
                  No activity records are loaded. Participation and reports
                  appear here after activity sessions are recorded.
                </p>
              </div>
            </div>

            <section className="content-panel people-panel">
              <div className="panel-heading">
                <h2>People you support</h2>
                <button
                  type="button"
                  className="btn btn-quiet"
                  onClick={() => setCaregiverSection("profiles")}
                >
                  View all
                </button>
              </div>
              {profiles.length === 0 ? (
                <p className="empty-state">
                  No elderly profiles have been added.
                </p>
              ) : (
                <div className="profile-list">
                  {profiles.map((profile) => (
                    <button
                      type="button"
                      className={`profile-row ${selectedProfile?.id === profile.id ? "selected" : ""}`}
                      key={profile.id}
                      onClick={() => setSelectedProfile(profile)}
                    >
                      <span className="profile-initial" aria-hidden="true">
                        {profileInitial(profile.display_name)}
                      </span>
                      <span>
                        <strong>{profile.display_name}</strong>
                        <span className="profile-language">
                          {languageLabel(profile.preferred_language)}
                        </span>
                      </span>
                    </button>
                  ))}
                </div>
              )}
            </section>
          </section>
        )}

        {caregiverSection === "profiles" && (
          <section className="profile-management">
            <div className="management-grid">
              <section className="content-panel">
                <div className="panel-heading">
                  <h2>Add an elderly profile</h2>
                </div>
                <form onSubmit={createProfile} className="management-form">
                  <label className="field">
                    Display name
                    <input
                      value={profileName}
                      onChange={(event) => setProfileName(event.target.value)}
                      required
                    />
                  </label>
                  <label className="field">
                    Preferred language
                    <select
                      value={profileLanguage}
                      onChange={(event) =>
                        setProfileLanguage(event.target.value)
                      }
                    >
                      <option value="en">English</option>
                      <option value="hi">Hindi</option>
                      <option value="mr">Marathi</option>
                    </select>
                  </label>
                  <button
                    className="btn btn-primary"
                    type="submit"
                    disabled={profileMutationLoading}
                  >
                    {profileMutationLoading ? "Saving..." : "Add profile"}
                  </button>
                </form>

                <div className="caregiver-name">
                  <h3>Your caregiver name</h3>
                  <form
                    onSubmit={saveCaregiverName}
                    className="management-form"
                  >
                    <label className="field">
                      Display name
                      <input
                        value={caregiverName}
                        onChange={(event) =>
                          setCaregiverName(event.target.value)
                        }
                      />
                    </label>
                    <button className="btn btn-primary" type="submit">
                      Save name
                    </button>
                  </form>
                </div>
              </section>

              <section className="content-panel">
                <div className="panel-heading">
                  <h2>Elderly profiles</h2>
                </div>
                {profilesLoading ? (
                  <p className="empty-state" role="status">
                    Loading elderly profiles...
                  </p>
                ) : profiles.length === 0 ? (
                  <p className="empty-state">
                    No elderly profiles have been added.
                  </p>
                ) : (
                  <div className="profile-list">
                    {profiles.map((profile) => (
                      <button
                        type="button"
                        className={`profile-row ${selectedProfile?.id === profile.id ? "selected" : ""}`}
                        key={profile.id}
                        onClick={() => setSelectedProfile(profile)}
                      >
                        <span className="profile-initial" aria-hidden="true">
                          {profileInitial(profile.display_name)}
                        </span>
                        <span>
                          <strong>{profile.display_name}</strong>
                          <span className="profile-language">
                            {languageLabel(profile.preferred_language)}
                          </span>
                        </span>
                      </button>
                    ))}
                  </div>
                )}

                {selectedProfile && (
                  <form className="edit-panel" onSubmit={updateProfile}>
                    <h3>Edit selected profile</h3>
                    <label className="field">
                      Display name
                      <input
                        value={selectedProfile.display_name}
                        onChange={(event) =>
                          setSelectedProfile({
                            ...selectedProfile,
                            display_name: event.target.value,
                          })
                        }
                        required
                      />
                    </label>
                    <label className="field">
                      Preferred language
                      <select
                        value={selectedProfile.preferred_language}
                        onChange={(event) =>
                          setSelectedProfile({
                            ...selectedProfile,
                            preferred_language: event.target.value,
                          })
                        }
                      >
                        <option value="en">English</option>
                        <option value="hi">Hindi</option>
                        <option value="mr">Marathi</option>
                      </select>
                    </label>
                    <div className="actions">
                      <button
                        className="btn btn-primary"
                        type="submit"
                        disabled={profileMutationLoading}
                      >
                        {profileMutationLoading ? "Saving..." : "Save changes"}
                      </button>
                      <button
                        className="btn btn-danger"
                        type="button"
                        disabled={profileMutationLoading}
                        onClick={() => deleteProfile(selectedProfile)}
                      >
                        Delete profile
                      </button>
                    </div>
                  </form>
                )}
              </section>
            </div>
          </section>
        )}

        {caregiverSection === "memory" && (
          <MemoryDecks user={user} selectedProfile={selectedProfile} />
        )}
        {caregiverSection === "activity" && (
          <CaregiverActivityHistory profiles={profiles} />
        )}
        {caregiverSection === "reports" && (
          <section className="content-panel feature-placeholder">
            <h2>Report export is not available yet</h2>
            <p>
              This area will export a factual engagement summary, not a clinical
              assessment.
            </p>
          </section>
        )}
        {caregiverSection === "wellbeing" && (
          <section className="content-panel wellbeing-panel">
            <h2>Caregiver wellbeing</h2>
            <p>
              Take regular breaks, ask for practical support, and connect with
              qualified local services when needed.
            </p>
            <div className="wellbeing-note">
              This is general information, not therapy or professional medical
              guidance.
            </div>
          </section>
        )}
      </section>
    </main>
  );
}

export default App;
