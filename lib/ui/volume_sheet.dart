import 'package:flutter/material.dart';

import '../src/intercom_service.dart';

/// Icon for a speaker volume (0 .. [IntercomCore.maxVolume]).
IconData speakerIcon(double volume) => volume == 0
    ? Icons.volume_off
    : (volume < 0.5 ? Icons.volume_down : Icons.volume_up);

/// Opens the volume controls: speaker and microphone, 0–200%. Changes apply
/// at once (also during a call) and are remembered.
Future<void> showVolumeSheet(BuildContext context, IntercomService service) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: VolumeControls(service: service),
        ),
      ),
    ),
  );
}

/// The two volume sliders.
class VolumeControls extends StatelessWidget {
  const VolumeControls({super.key, required this.service});

  final IntercomService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Volume', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _VolumeSlider(
            label: 'Speaker',
            help: 'How loud the other side plays here',
            icon: speakerIcon(service.speakerVolume),
            value: service.speakerVolume,
            onChanged: (v) => service.speakerVolume = v,
          ),
          _VolumeSlider(
            label: 'Microphone',
            help: 'How loud you are heard on the other side',
            icon: service.micVolume == 0 ? Icons.mic_off : Icons.mic,
            value: service.micVolume,
            onChanged: (v) => service.micVolume = v,
          ),
          if (service.speakerVolume > 1 || service.micVolume > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Above 100% boosts quiet audio; very loud voices may '
                'distort.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    required this.label,
    required this.help,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String help;
  final IconData icon;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final percent = (value * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(label, style: text.titleSmall),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  help,
                  style: text.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '$percent%',
                  textAlign: TextAlign.end,
                  style: text.labelLarge,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: value,
                  max: IntercomCore.maxVolume,
                  divisions: 40, // 5% steps.
                  label: '$percent%',
                  semanticFormatterCallback: (v) =>
                      '$label ${(v * 100).round()}%',
                  onChanged: onChanged,
                ),
              ),
              TextButton(
                onPressed: value == 1 ? null : () => onChanged(1),
                child: const Text('100%'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Call-screen button that opens the volume controls.
class VolumeButton extends StatelessWidget {
  const VolumeButton({super.key, required this.service});

  final IntercomService service;

  @override
  Widget build(BuildContext context) {
    final percent = (service.speakerVolume * 100).round();
    return FilledButton.tonalIcon(
      onPressed: () => showVolumeSheet(context, service),
      icon: Icon(speakerIcon(service.speakerVolume)),
      label: Text('$percent%'),
    );
  }
}
