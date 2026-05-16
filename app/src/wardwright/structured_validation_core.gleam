pub fn object_schema_valid(
  required_ok: Bool,
  additional_properties_ok: Bool,
  properties_ok: Bool,
) -> Bool {
  required_ok && additional_properties_ok && properties_ok
}

pub fn string_property_valid(
  is_string: Bool,
  string_length: Int,
  min_length: Int,
  enum_ok: Bool,
) -> Bool {
  is_string && string_length >= min_length && enum_ok
}

pub fn number_property_valid(
  is_number: Bool,
  gte_ok: Bool,
  lte_ok: Bool,
) -> Bool {
  is_number && gte_ok && lte_ok
}

pub fn string_array_property_valid(is_list: Bool, all_strings: Bool) -> Bool {
  is_list && all_strings
}

pub fn semantic_number_rule_valid(is_number: Bool, bounds_ok: Bool) -> Bool {
  is_number && bounds_ok
}

pub fn semantic_string_not_contains_valid(
  is_string: Bool,
  contains_pattern: Bool,
) -> Bool {
  case is_string {
    True -> !contains_pattern
    False -> True
  }
}
