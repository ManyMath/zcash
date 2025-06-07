class AddressValidation {
  final bool isValid;
  final String? address;
  final String? addressType;
  final bool? isMine;

  const AddressValidation({
    required this.isValid,
    this.address,
    this.addressType,
    this.isMine,
  });

  factory AddressValidation.fromJson(Map<String, dynamic> json) =>
      AddressValidation(
        isValid: json['isvalid'] as bool,
        address: json['address'] as String?,
        addressType: json['type'] as String?,
        isMine: json['ismine'] as bool?,
      );

  @override
  String toString() =>
      'AddressValidation(isValid: $isValid, type: $addressType)';
}
