import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:lander_flutter/lander_flutter.dart';

import 'app.dart';

const products = {'123': 'Trail runner', '456': 'Rain jacket'};

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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

/// Shows what Lander knows about a link.
class LinkDetails extends StatelessWidget {
  const LinkDetails({super.key, required this.link});

  final LanderLink? link;

  @override
  Widget build(BuildContext context) {
    final link = this.link;
    final rows = <(String, String)>[
      ('Install ID', Lander.installId ?? '(loading)'),
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
      ],
    ];
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Lander', style: Theme.of(context).textTheme.titleMedium),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: value),
              ])),
            ),
        ]),
      ),
    );
  }
}
