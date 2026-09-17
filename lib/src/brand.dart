/// TUM's own colours, for the few places the app has to speak with TUM's voice
/// rather than its own.
///
/// Everything else derives from the [ColorScheme] seeded with [tumBlue], which
/// is what makes the app feel of a piece in light and dark mode. The exceptions
/// live here: surfaces that must look the same in both themes because they are
/// telling the user something they cannot afford to skim past.
library;

import 'package:flutter/painting.dart';

/// TUM's brand blue, the same one gocast reports for its login button.
const Color tumBlue = Color(0xFF3070B3);

/// White on [tumBlue] is 5.1:1 — comfortably past WCAG AA for body text, and
/// legible on both themes without being repainted for either.
const Color onTumBlue = Color(0xFFFFFFFF);
