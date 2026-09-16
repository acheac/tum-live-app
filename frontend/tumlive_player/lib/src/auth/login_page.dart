/// Sign-in screen.
///
/// TUM-Live authenticates with SAML single sign-on, so there is nothing for us
/// to POST a password to — and asking for a TUM password in a third-party app
/// would be wrong even if it worked. The user authenticates in a real browser
/// and brings back the session cookie.
///
/// **This paste step is the prototype's one deliberate placeholder.** See
/// [AuthController.signInWithSessionCookie] for how to replace it with a
/// WebView flow once you target phones.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/api_exception.dart';
import '../app_scope.dart';
import 'auth_controller.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _cookieField = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _cookieField.dispose();
    super.dispose();
  }

  Future<void> _openSso() async {
    final AuthController auth = AppScope.authOf(context);
    final bool ok = await launchUrl(
      auth.ssoUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      setState(() => _error = 'Could not open a browser. Visit ${auth.ssoUrl}');
    }
  }

  Future<void> _signIn() async {
    final AuthController auth = AppScope.authOf(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.signInWithSessionCookie(_cookieField.text);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) {
        setState(
          () => _error = e.isUnauthorized
              ? 'That cookie was rejected. It may have expired — sign in again '
                    'and copy a fresh one.'
              : e.userMessage,
        );
      }
    } on NetworkException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to TUM-Live')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Signing in lets you see the courses you are enrolled in and '
                  'syncs your watch progress with TUM-Live.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                _StepCard(
                  step: '1',
                  title: 'Sign in with TUM Login',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'This opens TUM-Live in your browser and sends you '
                        'through the normal TUM single sign-on.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _busy ? null : _openSso,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open TUM Login'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _StepCard(
                  step: '2',
                  title: 'Copy your session cookie',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Once TUM-Live has loaded, open your browser\'s developer '
                        'tools (⌥⌘I on macOS), go to Application → Cookies → '
                        'https://tum.live, and copy the value of the cookie '
                        'named "jwt".',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _cookieField,
                        maxLines: 3,
                        minLines: 1,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'jwt cookie',
                          hintText: 'eyJhbGciOiJSUzI1NiIs…',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _busy ? null : _signIn(),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _signIn,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign in'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Browse public courses instead'),
                ),
                const SizedBox(height: 24),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.science_outlined,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Prototype note: copying a cookie by hand is a stand-in. '
                        'On phones this step becomes a WebView that completes '
                        'sign-in inside the app.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A numbered step in the sign-in instructions.
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.step,
    required this.title,
    required this.child,
  });

  final String step;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                step,
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  child,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
