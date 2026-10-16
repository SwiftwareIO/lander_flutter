import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lander_flutter/lander_flutter.dart';

import 'app.dart';

const products = {'123': 'Trail runner', '456': 'Rain jacket'};

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  /// Authenticated handoff: after sign in, ask Lander for a link your backend
  /// bound to this user with `POST /v1/handoffs`.
  Future<void> _signIn(BuildContext context) async {
    final userId = await showDialog<String>(context: context, builder: (_) => const SignInDialog());
    if (userId == null || userId.trim().isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      final link = await Lander.claimHandoff(userId);
      if (link == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Signed in. No link was waiting for you.')));
        return;
      }
      // Returned only, never also sent to onDeepLink, so navigate here.
      lastLink.value = link;
      router.go(link.route, extra: link);
    } on LanderException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not check for a handoff: ${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Acme Shop')),
        body: ListView(
          children: [
            for (final MapEntry(key: id, value: name) in products.entries)
              ListTile(
                title: Text(name),
                subtitle: Text('Product $id'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/product/$id'),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('Sign in'),
              subtitle: const Text('Claims a link handed off to your user ID'),
              onTap: () => _signIn(context),
            ),
            ValueListenableBuilder(
              valueListenable: lastLink,
              builder: (context, link, _) => LinkDetails(link: link),
            ),
          ],
        ),
      );
}

class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key, required this.id, this.link});

  final String id;
  final LanderLink? link;

  /// A probabilistic deferred link is a guess. Show the screen, but do not
  /// treat it as if the user had tapped it: no sign in, credit or offer.
  bool get isSuggestion => link?.confidence == LanderConfidence.probabilistic;

  Future<void> _share(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final short = await Lander.createLink(
        path: '/product/$id',
        params: {'productId': id},
        title: products[id],
        channel: 'share',
      );
      await Clipboard.setData(ClipboardData(text: short.url.toString()));
      messenger.showSnackBar(SnackBar(content: Text('Copied ${short.url}')));
    } on LanderException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not create a link: ${e.message}')));
    }
  }

  Future<void> _buy(BuildContext context) async {
    await Lander.trackEvent(
      'purchase',
      properties: {'productId': id, 'amount': 49.99, 'currency': 'USD'},
      // Attribute the purchase to the link that opened this screen, if any.
      linkId: link?.linkId,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Purchase tracked')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(products[id] ?? 'Product $id')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Product $id', style: Theme.of(context).textTheme.headlineSmall),
            if (isSuggestion) ...[
              const SizedBox(height: 8),
              const Text('Picked for you from a link you may have tapped before installing.'),
            ],
            const SizedBox(height: 16),
            Wrap(spacing: 8, children: [
              FilledButton.icon(
                onPressed: () => _buy(context),
                icon: const Icon(Icons.shopping_bag),
                label: const Text('Buy'),
              ),
              OutlinedButton.icon(
                onPressed: () => _share(context),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
            ]),
            if (link != null) ...[const SizedBox(height: 24), LinkDetails(link: link)],
          ],
        ),
      );
}

class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Not found')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('No screen for $uri'),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => context.go('/'), child: const Text('Home')),
          ]),
        ),
      );
}

class SignInDialog extends StatefulWidget {
  const SignInDialog({super.key});

  @override
  State<SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<SignInDialog> {
  final _userId = TextEditingController();

  @override
  void dispose() {
    _userId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Sign in'),
        content: TextField(
          controller: _userId,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'User ID', hintText: 'Your auth system user UUID'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _userId.text), child: const Text('Sign in')),
        ],
      );
}

/// Shows what Lander knows about a link.
class LinkDetails extends StatelessWidget {
  const LinkDetails({super.key, required this.link});

  final LanderLink? link;

  @override
  Widget build(BuildContext context) {
    final link = this.link;
    final rows = <(String, String)>[
      if (link == null) ('Last link', 'none yet'),
      if (link != null) ...[
        ('Opened URL', '${link.uri}'),
        ('Resolved', link.isResolved ? 'yes' : 'no (raw URL only)'),
        if (link.linkId != null) ('Link ID', link.linkId!),
        if (link.path != null) ('Path', link.path!),
        if (link.params.isNotEmpty) ('Params', '${link.params}'),
        if (link.campaign != null) ('Campaign', link.campaign!),
        if (link.channel != null) ('Channel', link.channel!),
        ('Deferred', '${link.isDeferred}'),
        ('Confidence', link.confidence.name),
        ('Method', link.method ?? 'none'),
      ],
    ];
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Lander', style: Theme.of(context).textTheme.titleMedium),
          ValueListenableBuilder(
            valueListenable: installId,
            builder: (context, id, _) => _row('Install ID', id ?? Lander.installId ?? '(loading)'),
          ),
          for (final (label, value) in rows) _row(label, value),
        ]),
      ),
    );
  }

  static Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(text: value),
        ])),
      );
}
