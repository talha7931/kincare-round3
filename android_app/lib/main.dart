import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_theme.dart';
import 'elderly_memory_screen.dart';
import 'memory_decks_screen.dart';

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_supabaseUrl.isEmpty || _supabasePublishableKey.isEmpty) {
    throw StateError(
      'Missing SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY dart-define values.',
    );
  }

  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _supabasePublishableKey,
  );

  runApp(const KinCareApp());
}

class KinCareApp extends StatelessWidget {
  const KinCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KinCare',
      debugShowCheckedModeBanner: false,
      theme: KinCareTheme.build(),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final StreamSubscription<AuthState> _authSubscription;
  User? _user;

  @override
  void initState() {
    super.initState();
    final client = Supabase.instance.client;
    _user = client.auth.currentUser;
    _authSubscription = client.auth.onAuthStateChange.listen((state) {
      setState(() => _user = state.session?.user);
    });
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _user == null ? const AuthScreen() : CaregiverScreen(user: _user!);
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _phoneOtpController = TextEditingController();
  bool _register = false;
  bool _phoneMode = false;
  bool _phoneOtpSent = false;
  bool _loading = false;
  String? _error;
  String? _authNotice;
  String _pendingEmail = '';
  int _resendCooldownSeconds = 0;
  Timer? _resendTimer;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    _phoneController.dispose();
    _phoneOtpController.dispose();
    super.dispose();
  }

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendCooldownSeconds = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _resendCooldownSeconds -= 1;
        if (_resendCooldownSeconds <= 0) {
          _resendCooldownSeconds = 0;
          _resendTimer?.cancel();
        }
      });
    });
  }

  String _friendlyAuthError(Object error) {
    final raw = error.toString().toLowerCase();
    if (raw.contains('rate limit') || raw.contains('429') || raw.contains('too many')) {
      return 'Too many verification requests. Please wait before trying again.';
    }
    if (raw.contains('already registered') || raw.contains('already been registered')) {
      return 'An account already exists for this email. Sign in or resend confirmation if verification is pending.';
    }
    if (raw.contains('email not confirmed') || raw.contains('email address not confirmed')) {
      return 'Verify your email address before signing in. Open the confirmation email or resend it below.';
    }
    if (raw.contains('invalid login credentials')) {
      return 'The email or password is incorrect.';
    }
    if (error is AuthException) return error.message;
    return 'Authentication failed. Please try again.';
  }

  Future<void> _submitPhone() async {
    if (_loading) return;
    final phone = _phoneController.text.trim();
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone)) {
      setState(() {
        _error = 'Enter an international phone number beginning with + and the country code.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _authNotice = null;
    });

    try {
      final auth = Supabase.instance.client.auth;
      if (!_phoneOtpSent) {
        await auth.signInWithOtp(phone: phone);
        setState(() {
          _phoneOtpSent = true;
          _authNotice = 'Enter the fixed test OTP configured for this test phone number in Supabase.';
        });
      } else {
        final otp = _phoneOtpController.text.trim();
        if (!RegExp(r'^\d{6}$').hasMatch(otp)) {
          setState(() {
            _error = 'Enter the 6-digit test OTP.';
          });
          return;
        }
        await auth.verifyOTP(phone: phone, token: otp, type: OtpType.sms);
        setState(() {
          _authNotice = 'Phone verification complete. Signing in...';
        });
      }
    } on AuthException catch (error) {
      setState(() => _error = _friendlyAuthError(error));
    } catch (error) {
      setState(() => _error = _friendlyAuthError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_loading || !_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final auth = Supabase.instance.client.auth;
      if (_register) {
        final response = await auth.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          data: {'display_name': _displayNameController.text.trim()},
        );
        if (response.session == null) {
          _pendingEmail = _emailController.text.trim();
          setState(() {
            _authNotice = 'Account created. Verify your email before signing in. Open the confirmation email sent to you.';
          });
        } else {
          setState(() {
            _authNotice = 'Account created and signed in.';
          });
        }
      } else {
        await auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
    } on AuthException catch (error) {
      final message = _friendlyAuthError(error);
      setState(() {
        _error = message;
        final raw = error.message.toLowerCase();
        if (raw.contains('email not confirmed') || raw.contains('email address not confirmed')) {
          _pendingEmail = _emailController.text.trim();
        }
      });
    } catch (error) {
      setState(() => _error = _friendlyAuthError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resendConfirmation() async {
    if (_loading || _resendCooldownSeconds > 0 || _pendingEmail.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _authNotice = null;
    });

    try {
      await Supabase.instance.client.auth.resend(
        type: OtpType.signup,
        email: _pendingEmail,
      );
      _startResendCooldown();
      setState(() {
        _authNotice = 'A new confirmation email was requested. Please wait for it to arrive.';
      });
    } on AuthException catch (error) {
      final message = _friendlyAuthError(error);
      setState(() => _error = message);
      if (message.startsWith('Too many verification requests')) {
        _startResendCooldown();
      }
    } catch (error) {
      setState(() => _error = _friendlyAuthError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KinCareColors.paleSage,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(KinCareSpace.x6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(KinCareSpace.x7),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              color: KinCareColors.forest,
                              shape: BoxShape.circle,
                            ),
                            child: const Text(
                              'K',
                              style: TextStyle(
                                color: KinCareColors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: KinCareSpace.x3),
                          const Text(
                            'KinCare',
                            style: TextStyle(
                              color: KinCareColors.forest,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: KinCareSpace.x6),
                      Text(
                        _phoneMode
                            ? 'Caregiver phone sign in'
                            : (_register
                                ? 'Create caregiver account'
                                : 'Caregiver sign in'),
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontSize: 30,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.6,
                              color: KinCareColors.forest,
                            ),
                      ),
                      const SizedBox(height: KinCareSpace.x5),
                      Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: KinCareColors.offWhite,
                          borderRadius: BorderRadius.circular(KinCareRadii.md),
                          border: Border.all(color: KinCareColors.line),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _MethodChoice(
                                label: 'Continue with Email',
                                selected: !_phoneMode,
                                onPressed: _loading ? null : () => setState(() {
                                  _phoneMode = false;
                                  _error = null;
                                  _authNotice = null;
                                }),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _MethodChoice(
                                label: 'Continue with Phone',
                                selected: _phoneMode,
                                onPressed: _loading ? null : () => setState(() {
                                  _phoneMode = true;
                                  _error = null;
                                  _authNotice = null;
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: KinCareSpace.x4),
                      if (_phoneMode) ...[
                        const _Notice(
                          tone: _NoticeTone.amber,
                          text: 'Prototype test authentication uses a configured Supabase test phone number and fixed test OTP. No SMS is sent.',
                        ),
                        const SizedBox(height: KinCareSpace.x3),
                        TextFormField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'International phone number', hintText: '+91...'),
                        ),
                        if (_phoneOtpSent) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _phoneOtpController,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            decoration: const InputDecoration(labelText: '6-digit test OTP'),
                          ),
                        ],
                      ] else ...[
                      if (_register)
                        TextFormField(
                          controller: _displayNameController,
                          decoration: const InputDecoration(labelText: 'Display name'),
                          validator: (value) => value == null || value.trim().isEmpty ? 'Enter a display name' : null,
                        ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email'),
                        validator: (value) => value == null || !value.contains('@') ? 'Enter a valid email' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'Password'),
                        validator: (value) {
                          if (value == null || value.length < 8) return 'Use at least 8 characters';
                          if (!RegExp(r'[A-Za-z]').hasMatch(value) || !RegExp(r'[0-9]').hasMatch(value)) {
                            return 'Use both letters and numbers';
                          }
                          return null;
                        },
                      ),
                      ],
                      if (_authNotice != null) ...[
                        const SizedBox(height: KinCareSpace.x3),
                        _Notice(tone: _NoticeTone.success, text: _authNotice!),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: KinCareSpace.x3),
                        _Notice(tone: _NoticeTone.error, text: _error!),
                      ],
                      const SizedBox(height: KinCareSpace.x5),
                      SizedBox(
                        height: KinCareSpace.x9,
                        child: FilledButton(
                          onPressed: _loading ? null : (_phoneMode ? _submitPhone : _submit),
                          child: Text(_phoneMode
                              ? (_phoneOtpSent ? 'Verify OTP' : 'Send test OTP')
                              : (_register ? 'Register' : 'Sign in')),
                        ),
                      ),
                      if (!_phoneMode && _pendingEmail.isNotEmpty)
                        TextButton(
                          onPressed: _loading || _resendCooldownSeconds > 0 ? null : _resendConfirmation,
                          child: Text(_resendCooldownSeconds > 0
                              ? 'Resend confirmation in ${_resendCooldownSeconds}s'
                              : 'Resend confirmation email'),
                        ),
                      if (!_phoneMode)
                        TextButton(
                        onPressed: _loading ? null : () => setState(() {
                          _register = !_register;
                          _error = null;
                          _authNotice = null;
                        }),
                        child: Text(_register ? 'Back to sign in' : 'Create an account'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CaregiverScreen extends StatefulWidget {
  final User user;

  const CaregiverScreen({super.key, required this.user});

  @override
  State<CaregiverScreen> createState() => _CaregiverScreenState();
}

class _CaregiverScreenState extends State<CaregiverScreen> {
  final _client = Supabase.instance.client;
  final _caregiverNameController = TextEditingController();
  final _profileNameController = TextEditingController();
  String _profileLanguage = 'en';
  String? _selectedProfileId;
  Map<String, dynamic>? _selectedProfile;
  List<Map<String, dynamic>> _profiles = [];
  String? _error;
  bool _loading = true;
  bool _profileMutationLoading = false;
  bool _seniorMode = false;
  String _caregiverSection = 'profiles';

  /// Presentation only: which unavailable activity the elderly user opened.
  String? _openActivityKey;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _caregiverNameController.dispose();
    _profileNameController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final caregiver = await _client
          .from('caregivers')
          .select('display_name')
          .eq('id', widget.user.id)
          .maybeSingle();

      if (caregiver == null) {
        final fallback = widget.user.userMetadata?['display_name']?.toString() ?? '';
        await _client.from('caregivers').insert({
          'id': widget.user.id,
          'display_name': fallback.isEmpty ? null : fallback,
        });
        _caregiverNameController.text = fallback;
      } else {
        _caregiverNameController.text = caregiver['display_name']?.toString() ?? '';
      }

      await _loadProfiles();
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadProfiles() async {
    final data = await _client
      .from('elderly_profiles')
        .select('id, display_name, preferred_language')
        .eq('caregiver_id', widget.user.id)
        .order('created_at');

    setState(() {
      _profiles = List<Map<String, dynamic>>.from(data);
      if (_selectedProfileId != null) {
        _selectedProfile = _profiles.cast<Map<String, dynamic>?>().firstWhere(
              (profile) => profile?['id'] == _selectedProfileId,
              orElse: () => null,
            );
      }
    });
  }

  Future<void> _saveCaregiverName() async {
    if (_profileMutationLoading) return;
    setState(() {
      _error = null;
      _profileMutationLoading = true;
    });
    try {
      await _client
          .from('caregivers')
          .update({'display_name': _caregiverNameController.text.trim().isEmpty ? null : _caregiverNameController.text.trim()})
          .eq('id', widget.user.id);
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _profileMutationLoading = false);
    }
  }

  Future<void> _createProfile() async {
    if (_profileMutationLoading || _profileNameController.text.trim().isEmpty) return;
    setState(() {
      _error = null;
      _profileMutationLoading = true;
    });
    try {
      await _client.from('elderly_profiles').insert({
        'caregiver_id': widget.user.id,
        'display_name': _profileNameController.text.trim(),
        'preferred_language': _profileLanguage,
      });
      _profileNameController.clear();
      setState(() => _profileLanguage = 'en');
      await _loadProfiles();
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _profileMutationLoading = false);
    }
  }

  Future<void> _updateProfile() async {
    if (_profileMutationLoading || _selectedProfile == null) return;
    setState(() {
      _error = null;
      _profileMutationLoading = true;
    });
    try {
      await _client
          .from('elderly_profiles')
          .update({
            'display_name': _selectedProfile!['display_name'].toString().trim(),
            'preferred_language': _selectedProfile!['preferred_language'].toString(),
          })
          .eq('id', _selectedProfileId!);
      await _loadProfiles();
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _profileMutationLoading = false);
    }
  }

  Future<void> _deleteProfile(Map<String, dynamic> profile) async {
    if (_profileMutationLoading) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete profile'),
        content: Text('Delete ${profile['display_name']}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed != true) return;
    setState(() {
      _error = null;
      _profileMutationLoading = true;
    });
    try {
      await _client.from('elderly_profiles').delete().eq('id', profile['id']);
      if (_selectedProfileId == profile['id']) {
        setState(() {
          _selectedProfileId = null;
          _selectedProfile = null;
        });
      }
      await _loadProfiles();
    } catch (error) {
      final message = error.toString();
      setState(() => _error = message.toLowerCase().contains('foreign key')
          ? 'This profile has dependent records and cannot be deleted yet.'
          : message);
    } finally {
      if (mounted) setState(() => _profileMutationLoading = false);
    }
  }

  Future<void> _signOut() async {
    await _client.auth.signOut();
  }

  Widget _buildSeniorMode() {
    final selectedProfile = _selectedProfile;

    if (_openActivityKey != null) {
      if (_openActivityKey == 'memory' && selectedProfile != null) {
        return ElderlyMemoryScreen(
          selectedProfile: selectedProfile,
          onBack: () => setState(() => _openActivityKey = null),
          onHome: () => setState(() {
            _openActivityKey = null;
            _selectedProfileId = null;
            _selectedProfile = null;
          }),
        );
      }

      final activity = _seniorActivities.firstWhere(
        (item) => item.key == _openActivityKey,
        orElse: () => _seniorActivities.first,
      );
      return SingleChildScrollView(
        padding: const EdgeInsets.all(KinCareSpace.x5),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: KinCareSenior.controlHeight,
                        child: FilledButton(
                          onPressed: () =>
                              setState(() => _openActivityKey = null),
                          style: FilledButton.styleFrom(
                            backgroundColor: KinCareColors.sage,
                          ),
                          child: const Text('Back', style: TextStyle(fontSize: 19)),
                        ),
                      ),
                    ),
                    const SizedBox(width: KinCareSpace.x3),
                    Expanded(
                      child: SizedBox(
                        height: KinCareSenior.controlHeight,
                        child: FilledButton(
                          onPressed: () => setState(() {
                            _openActivityKey = null;
                            _selectedProfileId = null;
                            _selectedProfile = null;
                          }),
                          child: const Text('Home', style: TextStyle(fontSize: 19)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: KinCareSpace.x6),
                Container(
                  padding: const EdgeInsets.all(KinCareSpace.x7),
                  decoration: BoxDecoration(
                    color: KinCareColors.white,
                    borderRadius: BorderRadius.circular(KinCareRadii.xl),
                    border: Border.all(color: KinCareColors.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activity.name,
                        style: const TextStyle(
                          fontSize: 34,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: KinCareColors.forest,
                        ),
                      ),
                      const SizedBox(height: KinCareSpace.x4),
                      const Text(
                        'This activity is not ready yet. Ask your caregiver to set it up.',
                        style: TextStyle(
                          fontSize: KinCareSenior.body,
                          height: 1.4,
                          color: KinCareColors.charcoal,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (selectedProfile == null) {
      final double tileHeight = MediaQuery.sizeOf(context).width < 700
          ? KinCareSenior.tileMinNarrow
          : KinCareSenior.tileMin;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(KinCareSpace.x6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Who is using KinCare?',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: KinCareSenior.title,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: KinCareColors.forest,
                  ),
                ),
                const SizedBox(height: KinCareSpace.x6),
                if (_profiles.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(KinCareSpace.x7),
                    decoration: BoxDecoration(
                      color: KinCareColors.white,
                      borderRadius: BorderRadius.circular(KinCareRadii.xl),
                      border: Border.all(color: KinCareColors.cloud, width: 3),
                    ),
                    child: const Text(
                      'No elderly profiles are available. Ask the caregiver to add one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: KinCareSenior.body,
                        height: 1.4,
                        color: KinCareColors.charcoal,
                      ),
                    ),
                  )
                else
                  for (final profile in _profiles)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: SizedBox(
                        height: tileHeight,
                        child: Material(
                          color: KinCareColors.paleSage,
                          borderRadius: BorderRadius.circular(KinCareRadii.xl),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => setState(() {
                              _selectedProfileId = profile['id'].toString();
                              _selectedProfile =
                                  Map<String, dynamic>.from(profile);
                            }),
                            child: Center(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 64,
                                    height: 64,
                                    alignment: Alignment.center,
                                    decoration: const BoxDecoration(
                                      color: KinCareColors.white,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      profileInitial(profile['display_name']),
                                      style: const TextStyle(
                                        fontSize: 26,
                                        fontWeight: FontWeight.w700,
                                        color: KinCareColors.forest,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: KinCareSpace.x4),
                                  Flexible(
                                    child: Text(
                                      profile['display_name'].toString(),
                                      style: const TextStyle(
                                        fontSize: KinCareSenior.name,
                                        height: 1.25,
                                        fontWeight: FontWeight.w700,
                                        color: KinCareColors.forest,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(KinCareSpace.x6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: KinCareSenior.controlHeight,
                      child: FilledButton(
                        onPressed: () => setState(() {
                          _openActivityKey = null;
                          _selectedProfileId = null;
                          _selectedProfile = null;
                        }),
                        style: FilledButton.styleFrom(
                          backgroundColor: KinCareColors.sage,
                        ),
                        child: const Text('Back', style: TextStyle(fontSize: 19)),
                      ),
                    ),
                  ),
                  const SizedBox(width: KinCareSpace.x3),
                  Expanded(
                    child: SizedBox(
                      height: KinCareSenior.controlHeight,
                      child: FilledButton(
                        onPressed: () => setState(() {
                          _openActivityKey = null;
                          _selectedProfileId = null;
                          _selectedProfile = null;
                        }),
                        child: const Text('Home', style: TextStyle(fontSize: 19)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: KinCareSpace.x7),
              Text(
                'Hello, ${selectedProfile['display_name']}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: KinCareSenior.title,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: KinCareColors.forest,
                ),
              ),
              const SizedBox(height: KinCareSpace.x3),
              const Text(
                'Choose an activity',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: KinCareSenior.body,
                  color: KinCareColors.charcoal,
                ),
              ),
              const SizedBox(height: KinCareSpace.x6),
              Container(
                padding: const EdgeInsets.all(KinCareSpace.x2),
                decoration: BoxDecoration(
                  color: KinCareColors.cloud,
                  borderRadius: BorderRadius.circular(KinCareRadii.xl),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var index = 0;
                        index < _seniorActivities.length;
                        index++) ...[
                      if (index > 0)
                        const Divider(
                          height: 1,
                          thickness: 1,
                          color: Color(0x24263238),
                        ),
                      InkWell(
                        onTap: () => setState(
                          () => _openActivityKey = _seniorActivities[index].key,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: KinCareSpace.x6,
                            vertical: 22,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _seniorActivities[index].name,
                                style: const TextStyle(
                                  fontSize: 26,
                                  height: 1.3,
                                  fontWeight: FontWeight.w600,
                                  color: KinCareColors.forest,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _seniorActivities[index].description,
                                style: const TextStyle(
                                  fontSize: 21,
                                  height: 1.4,
                                  color: KinCareColors.charcoal,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _seniorActivities[index].availability,
                                style: const TextStyle(
                                  fontSize: 17,
                                  height: 1.4,
                                  fontWeight: FontWeight.w600,
                                  color: KinCareColors.charcoal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_seniorMode ? 'KinCare' : 'KinCare caregiver profiles'),
        actions: [
          if (!_seniorMode) ...[
            TextButton(
              onPressed: () => setState(() => _caregiverSection = 'profiles'),
              style: TextButton.styleFrom(
                foregroundColor: _caregiverSection == 'profiles'
                    ? KinCareColors.forest
                    : KinCareColors.textMuted,
              ),
              child: const Text('Profiles'),
            ),
            TextButton(
              onPressed: () => setState(() => _caregiverSection = 'memory'),
              style: TextButton.styleFrom(
                foregroundColor: _caregiverSection == 'memory'
                    ? KinCareColors.forest
                    : KinCareColors.textMuted,
              ),
              child: const Text('Memory Decks'),
            ),
          ],
          TextButton(
            onPressed: () => setState(() {
              _seniorMode = !_seniorMode;
              _openActivityKey = null;
            }),
            child: Text(_seniorMode ? 'Caregiver mode' : 'Elderly mode'),
          ),
          IconButton(onPressed: _signOut, tooltip: 'Sign out', icon: const Icon(Icons.logout)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _seniorMode
              ? _buildSeniorMode()
          : _caregiverSection == 'memory'
              ? MemoryDecksScreen(user: widget.user, selectedProfile: _selectedProfile)
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final stacked = constraints.maxWidth < 700;
                      final left = Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('Your profile', style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 12),
                              TextField(controller: _caregiverNameController, decoration: const InputDecoration(labelText: 'Display name')),
                              const SizedBox(height: 12),
                              FilledButton(onPressed: _profileMutationLoading ? null : _saveCaregiverName, child: const Text('Save name')),
                              const SizedBox(height: KinCareSpace.x6),
                              const Divider(),
                              const SizedBox(height: KinCareSpace.x6),
                              Text('Add elderly profile', style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 12),
                              TextField(controller: _profileNameController, decoration: const InputDecoration(labelText: 'Display name')),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<String>(
                                initialValue: _profileLanguage,
                                decoration: const InputDecoration(labelText: 'Preferred language'),
                                items: const [
                                  DropdownMenuItem(value: 'en', child: Text('English')),
                                  DropdownMenuItem(value: 'hi', child: Text('Hindi')),
                                  DropdownMenuItem(value: 'mr', child: Text('Marathi')),
                                ],
                                onChanged: (value) => setState(() => _profileLanguage = value ?? 'en'),
                              ),
                              const SizedBox(height: 12),
                              FilledButton(onPressed: _profileMutationLoading ? null : _createProfile, child: Text(_profileMutationLoading ? 'Saving...' : 'Add profile')),
                            ],
                          ),
                        ),
                      );

                      final right = Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('Elderly profiles', style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 12),
                              if (_profiles.isEmpty)
                                const Text(
                                  'No elderly profiles have been added.',
                                  style: TextStyle(color: KinCareColors.textMuted),
                                ),
                              for (final profile in _profiles)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 2),
                                  decoration: BoxDecoration(
                                    color:
                                        _selectedProfileId == profile['id']
                                            ? KinCareColors.paleSage
                                            : Colors.transparent,
                                    borderRadius:
                                        BorderRadius.circular(KinCareRadii.md),
                                  ),
                                  child: InkWell(
                                    borderRadius:
                                        BorderRadius.circular(KinCareRadii.md),
                                    onTap: () => setState(() {
                                      _selectedProfileId = profile['id'];
                                      _selectedProfile =
                                          Map<String, dynamic>.from(profile);
                                    }),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: KinCareSpace.x2,
                                        vertical: KinCareSpace.x3,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 44,
                                            height: 44,
                                            alignment: Alignment.center,
                                            decoration: BoxDecoration(
                                              color: _selectedProfileId ==
                                                      profile['id']
                                                  ? KinCareColors.white
                                                  : KinCareColors.paleSage,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Text(
                                              profileInitial(
                                                profile['display_name'],
                                              ),
                                              style: const TextStyle(
                                                fontSize: 17,
                                                fontWeight: FontWeight.w700,
                                                color: KinCareColors.forest,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: KinCareSpace.x3),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  profile['display_name']
                                                      .toString(),
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w600,
                                                    color: KinCareColors.forest,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  languageLabel(
                                                    profile['preferred_language'],
                                                  ),
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                    color: KinCareColors
                                                        .textMuted,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Delete profile',
                                            icon: const Icon(
                                              Icons.delete_outline,
                                            ),
                                            onPressed:
                                                _profileMutationLoading
                                                    ? null
                                                    : () =>
                                                        _deleteProfile(profile),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              if (_selectedProfile != null) ...[
                                const Divider(),
                                Text('Edit selected profile', style: Theme.of(context).textTheme.titleMedium),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: TextEditingController.fromValue(
                                    TextEditingValue(text: _selectedProfile!['display_name'].toString()),
                                  ),
                                  onChanged: (value) => _selectedProfile!['display_name'] = value,
                                  decoration: const InputDecoration(labelText: 'Display name'),
                                ),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                  initialValue: _selectedProfile!['preferred_language'],
                                  decoration: const InputDecoration(labelText: 'Preferred language'),
                                  items: const [
                                    DropdownMenuItem(value: 'en', child: Text('English')),
                                    DropdownMenuItem(value: 'hi', child: Text('Hindi')),
                                    DropdownMenuItem(value: 'mr', child: Text('Marathi')),
                                  ],
                                  onChanged: (value) => setState(() => _selectedProfile!['preferred_language'] = value ?? 'en'),
                                ),
                                const SizedBox(height: 12),
                                FilledButton(onPressed: _profileMutationLoading ? null : _updateProfile, child: Text(_profileMutationLoading ? 'Saving...' : 'Save changes')),
                              ],
                            ],
                          ),
                        ),
                      );

                      if (_error != null) {
                        return Column(children: [_Notice(tone: _NoticeTone.error, text: _error!), const SizedBox(height: KinCareSpace.x4), if (stacked) ...[left, const SizedBox(height: 12), right] else Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 300, child: left), const SizedBox(width: 16), Expanded(child: right)])]);
                      }
                      if (stacked) return Column(children: [left, const SizedBox(height: 12), right]);
                      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 300, child: left), const SizedBox(width: 16), Expanded(child: right)]);
                    },
                  ),
                ),
              ),
            ),
    );
  }
}

/// One entry in the elderly activity board. None of them are implemented yet,
/// so the availability line is part of the model rather than a start control.
class _SeniorActivity {
  const _SeniorActivity(this.key, this.name, this.description, this.availability);

  final String key;
  final String name;
  final String description;
  final String availability;
}

const List<_SeniorActivity> _seniorActivities = [
  _SeniorActivity(
    'memory',
    'Memory Decks',
    'Look at familiar photographs and share a memory.',
    'Available after cards are added',
  ),
  _SeniorActivity(
    'odd',
    'Odd One Out',
    'Choose the item that is different.',
    'Available after setup',
  ),
  _SeniorActivity(
    'sorting',
    'Everyday Object Sorting',
    'Place familiar objects in the right group.',
    'Available after setup',
  ),
];

enum _NoticeTone { success, amber, error }

/// Tonal notice surface. Replaces bare coloured text and left-border stripes
/// with a full hairline border so status reads without an accent bar.
class _Notice extends StatelessWidget {
  const _Notice({required this.tone, required this.text});

  final _NoticeTone tone;
  final String text;

  @override
  Widget build(BuildContext context) {
    final (Color background, Color border, Color foreground) = switch (tone) {
      _NoticeTone.success => (
          KinCareColors.paleSage,
          KinCareColors.sage.withValues(alpha: 0.28),
          KinCareColors.forest,
        ),
      _NoticeTone.amber => (
          KinCareColors.amberWash,
          KinCareColors.amberLine,
          KinCareColors.charcoal,
        ),
      _NoticeTone.error => (
          KinCareColors.dangerWash,
          KinCareColors.dangerLine,
          KinCareColors.danger,
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: KinCareSpace.x4,
        vertical: KinCareSpace.x3,
      ),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(KinCareRadii.sm),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14.5,
          height: 1.55,
          fontWeight: FontWeight.w500,
          color: foreground,
        ),
      ),
    );
  }
}

/// Paired authentication choice. Selection is carried by a filled surface and
/// border, never by an icon alone.
class _MethodChoice extends StatelessWidget {
  const _MethodChoice({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, KinCareSpace.x9),
        padding: const EdgeInsets.symmetric(horizontal: KinCareSpace.x2),
        backgroundColor:
            selected ? KinCareColors.paleSage : Colors.transparent,
        foregroundColor:
            selected ? KinCareColors.forest : KinCareColors.textMuted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KinCareRadii.sm),
          side: selected
              ? BorderSide(color: KinCareColors.sage.withValues(alpha: 0.35))
              : BorderSide.none,
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 2,
        style: TextStyle(
          fontSize: 15,
          height: 1.25,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
    );
  }
}
