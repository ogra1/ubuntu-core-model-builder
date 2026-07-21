import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';
import '../models/model_assertion.dart';

class MetadataPage extends StatelessWidget {
  final ModelAssertion model;
  final VoidCallback onChanged;
  const MetadataPage({
    super.key,
    required this.model,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Model Metadata',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('Model Identity'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextFormField(
                  initialValue: model.model,
                  decoration: const InputDecoration(
                    labelText: 'Model name',
                    helperText: 'Lowercase, alphanumeric and dashes',
                  ),
                  onChanged: (v) {
                    model.model = v;
                    onChanged();
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: ValueKey(model.brandId),
                  initialValue: model.brandId ?? 'Not signed in',
                  readOnly: true,
                  decoration: const InputDecoration(
                    labelText: 'Brand ID (auto)',
                    helperText: 'Derived from your store account',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('System'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                DropdownButtonFormField<ModelArchitecture>(
                  value: model.architecture,
                  decoration: const InputDecoration(labelText: 'Architecture'),
                  items: ModelArchitecture.values
                      .map((a) =>
                          DropdownMenuItem(value: a, child: Text(a.name)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) model.architecture = v;
                    onChanged();
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: model.base,
                  decoration: const InputDecoration(labelText: 'Base'),
                  items: const ['core22', 'core24', 'core26']
                      .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                      .toList(),
                  onChanged: (v) {
                    model.base = v;
                    onChanged();
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        YaruSection(
          headline: const Text('Grade'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<ModelGrade>(
              segments: ModelGrade.values
                  .map((g) => ButtonSegment(value: g, label: Text(g.name)))
                  .toList(),
              selected: {model.grade},
              onSelectionChanged: (selection) {
                model.grade = selection.first;
                onChanged();
              },
            ),
          ),
        ),
      ],
    );
  }
}
