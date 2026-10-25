#import "NNCore.h"

NSDictionary<NSString *, NSNumber *> *styleNames(void) {
  return @{@"title": @0, @"heading": @1, @"subheading": @2, @"body": @3, @"monospaced": @4,
           @"bullet": @100, @"dash": @101, @"numbered": @102, @"checklist": @103};
}

NSString *styleName(long s) {
  for (NSString *k in styleNames()) if (styleNames()[k].longValue == s) return k;
  return [NSString stringWithFormat:@"style%ld", s];
}

// TTEmphasis values, confirmed in Notes.app's highlight menu (macOS 27.2).
NSArray<NSString *> *highlightNames(void) { return @[@"purple", @"pink", @"orange", @"mint", @"blue"]; }

id highlightName(NSNumber *v) {
  NSInteger i = v.integerValue;
  return i >= 1 && i <= 5 ? highlightNames()[i - 1] : v;
}

// "pink" or "2" -> 2; "none" or "0" -> 0; anything else -> -1.
NSInteger highlightValue(NSString *s) {
  s = s.lowercaseString;
  NSUInteger i = [highlightNames() indexOfObject:s];
  if (i != NSNotFound) return (NSInteger)i + 1;
  if ([s isEqualToString:@"none"]) return 0;
  NSInteger n = s.integerValue;
  return [s isEqualToString:[@(n) stringValue]] && n >= 0 && n <= 5 ? n : -1;
}

#pragma mark - Output

void emit(id obj) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:obj
                                              options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                error:NULL];
  fwrite(d.bytes, 1, d.length, stdout);
  fputc('\n', stdout);
}

__attribute__((noreturn)) void fail(NSString *code, NSString *message) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"error": code, @"message": message ?: @""} options:0 error:NULL];
  fwrite(d.bytes, 1, d.length, stderr);
  fputc('\n', stderr);
  exit(1);
}
