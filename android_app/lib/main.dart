import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF477568),
          primary: const Color(0xFF183D35),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F4F3),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
        ),
      ),
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
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('KINCARE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(_phoneMode ? 'Caregiver phone sign in' : (_register ? 'Create caregiver account' : 'Caregiver sign in'), style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _loading ? null : () => setState(() {
                                _phoneMode = false;
                                _error = null;
                                _authNotice = null;
                              }),
                              child: const Text('Continue with Email'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _loading ? null : () => setState(() {
                                _phoneMode = true;
                                _error = null;
                                _authNotice = null;
                              }),
                              child: const Text('Continue with Phone'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_phoneMode) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          color: const Color(0xFFFBF6EC),
                          child: const Text(
                            'Prototype test authentication uses a configured Supabase test phone number and fixed test OTP. No SMS is sent.',
                          ),
                        ),
                        const SizedBox(height: 12),
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
                        const SizedBox(height: 12),
                        Text(_authNotice!, style: const TextStyle(color: Color(0xFF183D35))),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: Colors.red)),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _loading ? null : (_phoneMode ? _submitPhone : _submit),
                        child: Text(_phoneMode
                            ? (_phoneOtpSent ? 'Verify OTP' : 'Send test OTP')
                            : (_register ? 'Register' : 'Sign in')),
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
          .from('CAREGIVERS')
          .select('display_name')
          .eq('id', widget.user.id)
          .maybeSingle();

      if (caregiver == null) {
        final fallback = widget.user.userMetadata?['display_name']?.toString() ?? '';
        await _client.from('CAREGIVERS').insert({
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
        .from('ELDERLY_PROFILES')
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
          .from('CAREGIVERS')
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
      await _client.from('ELDERLY_PROFILES').insert({
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
          .from('ELDERLY_PROFILES')
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
      await _client.from('ELDERLY_PROFILES').delete().eq('id', profile['id']);
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
    if (selectedProfile == null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Who is using KinCare?',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: const Color(0xFF183D35),
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 24),
                if (_profiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No elderly profiles are available. Ask the caregiver to add one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22),
                    ),
                  )
                else
                  for (final profile in _profiles)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: SizedBox(
                        height: 84,
                        child: FilledButton.icon(
                          onPressed: () => setState(() {
                            _selectedProfileId = profile['id'].toString();
                            _selectedProfile = Map<String, dynamic>.from(profile);
                          }),
                          icon: const Icon(Icons.person_outline, size: 30),
                          label: Text(
                            profile['display_name'].toString(),
                            style: const TextStyle(fontSize: 24),
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
      padding: const EdgeInsets.all(24),
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
                      height: 68,
                      child: FilledButton.tonalIcon(
                        onPressed: () => setState(() {
                          _selectedProfileId = null;
                          _selectedProfile = null;
                        }),
                        icon: const Icon(Icons.arrow_back, size: 26),
                        label: const Text('Back', style: TextStyle(fontSize: 22)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 68,
                      child: FilledButton.icon(
                        onPressed: () => setState(() {
                          _selectedProfileId = null;
                          _selectedProfile = null;
                        }),
                        icon: const Icon(Icons.home_outlined, size: 26),
                        label: const Text('Home', style: TextStyle(fontSize: 22)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                'Hello, ${selectedProfile['display_name']}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: const Color(0xFF183D35),
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Choose an activity',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24),
              ),
              const SizedBox(height: 24),
              for (final title in const [
                'Memory Decks',
                'Odd One Out',
                'Object Sorting',
              ])
                Card(
                  margin: const EdgeInsets.only(bottom: 16),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Color(0xFF183D35),
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 68,
                          child: FilledButton(
                            onPressed: null,
                            child: Text(
                              'Not available yet',
                              style: const TextStyle(fontSize: 20),
                            ),
                          ),
                        ),
                      ],
                    ),
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
          TextButton(
            onPressed: () => setState(() => _seniorMode = !_seniorMode),
            child: Text(_seniorMode ? 'Caregiver mode' : 'Elderly mode'),
          ),
          IconButton(onPressed: _signOut, tooltip: 'Sign out', icon: const Icon(Icons.logout)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _seniorMode
              ? _buildSeniorMode()
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
                              const SizedBox(height: 24),
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
                                const Text('No elderly profiles have been added.'),
                              for (final profile in _profiles)
                                ListTile(
                                  selected: _selectedProfileId == profile['id'],
                                  title: Text(profile['display_name']),
                                  subtitle: Text(profile['preferred_language']),
                                  onTap: () => setState(() {
                                    _selectedProfileId = profile['id'];
                                    _selectedProfile = Map<String, dynamic>.from(profile);
                                  }),
                                  trailing: IconButton(
                                    tooltip: 'Delete profile',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: _profileMutationLoading ? null : () => _deleteProfile(profile),
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
                        return Column(children: [Text(_error!, style: const TextStyle(color: Colors.red)), const SizedBox(height: 12), if (stacked) ...[left, const SizedBox(height: 12), right] else Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 300, child: left), const SizedBox(width: 16), Expanded(child: right)])]);
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
