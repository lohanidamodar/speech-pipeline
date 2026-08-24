import 'dart:math' as math;
import 'dart:typed_data';

import 'engines.dart';

/// Conversions between the 16-bit PCM that audio devices and wire protocols
/// use and the normalised floats every sherpa-onnx entry point expects.
AudioChunk pcm16ToFloat32(Uint8List bytes) {
  final samples = bytes.lengthInBytes ~/ 2;
  final view = ByteData.sublistView(bytes);
  final out = Float32List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

Uint8List float32ToPcm16(AudioChunk samples) {
  final out = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    out.setInt16(i * 2, v, Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Regroups an arbitrarily chunked byte stream into fixed-size sample frames.
///
/// The VAD wants a steady frame size; stdin and sockets deliver whatever the
/// kernel happened to have. [frameSize] should be a multiple of the VAD window.
Stream<AudioChunk> framePcm16(
  Stream<List<int>> bytes, {
  int frameSize = 1024,
}) async* {
  final carry = BytesBuilder(copy: false);
  final frameBytes = frameSize * 2;

  await for (final data in bytes) {
    carry.add(data);
    if (carry.length < frameBytes) continue;

    final buffered = carry.takeBytes();
    var offset = 0;
    while (buffered.length - offset >= frameBytes) {
      yield pcm16ToFloat32(
        Uint8List.sublistView(buffered, offset, offset + frameBytes),
      );
      offset += frameBytes;
    }
    if (offset < buffered.length) {
      carry.add(Uint8List.sublistView(buffered, offset));
    }
  }
}

/// Band-limited resampler (windowed-sinc).
///
/// Linear interpolation is not good enough here. Every voice in this project
/// outputs above 16 kHz — Kokoro at 24 kHz, Piper at 22.05 kHz — and dropping
/// to the recogniser's rate without a low-pass folds everything above 8 kHz
/// back down into the speech band. That aliasing lands squarely on the
/// consonants ASR relies on.
///
/// [zeroCrossings] trades cost for stopband rejection; 8 is comfortably enough
/// for speech.
AudioChunk resample(
  AudioChunk input,
  int fromRate,
  int toRate, {
  int zeroCrossings = 8,
}) {
  if (fromRate == toRate || input.isEmpty) return input;

  final ratio = toRate / fromRate;
  // Cut off at the lower of the two Nyquist limits, in source-rate cycles.
  final cutoff = (ratio < 1.0 ? ratio : 1.0) * 0.5;
  final halfWidth = (zeroCrossings / (2 * cutoff)).ceil();

  final outLength = (input.length * ratio).floor();
  final out = Float32List(outLength);

  for (var i = 0; i < outLength; i++) {
    final center = i / ratio;
    final first = (center - halfWidth).ceil();
    final last = (center + halfWidth).floor();

    var sum = 0.0;
    var weight = 0.0;
    for (var j = first; j <= last; j++) {
      if (j < 0 || j >= input.length) continue;
      final t = center - j;
      final tap = _sinc(2 * cutoff * t) * _blackman(t / halfWidth);
      sum += input[j] * tap;
      weight += tap;
    }
    // Normalising by the realised weight keeps gain flat at the edges, where
    // part of the kernel hangs off the end of the buffer.
    out[i] = weight.abs() > 1e-9 ? sum / weight : 0.0;
  }
  return out;
}

double _sinc(double x) {
  if (x.abs() < 1e-9) return 1.0;
  final pix = math.pi * x;
  return math.sin(pix) / pix;
}

double _blackman(double t) {
  if (t.abs() >= 1.0) return 0.0;
  final x = math.pi * (t + 1.0);
  return 0.42 - 0.5 * math.cos(x) + 0.08 * math.cos(2 * x);
}

/// Minimal RIFF header for streaming playback tools that need one.
Uint8List wavHeader({required int sampleRate, required int dataLength}) {
  final h = ByteData(44);
  void tag(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      h.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + dataLength, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, 1, Endian.little); // mono
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  h.setUint16(32, 2, Endian.little); // block align
  h.setUint16(34, 16, Endian.little); // bits per sample
  tag(36, 'data');
  h.setUint32(40, dataLength, Endian.little);
  return h.buffer.asUint8List();
}
