enum NsfwInputNormalization { zeroToOne, minusOneToOne }

extension NsfwInputNormalizationWire on NsfwInputNormalization {
  String get wireValue {
    switch (this) {
      case NsfwInputNormalization.zeroToOne:
        return 'zero_to_one';
      case NsfwInputNormalization.minusOneToOne:
        return 'minus_one_to_one';
    }
  }
}
