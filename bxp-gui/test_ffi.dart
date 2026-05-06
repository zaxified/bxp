import 'package:ffi/ffi.dart';
import 'dart:ffi';
import 'dart:io';

typedef BxpValidateExprC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef BxpValidateExprDart = Pointer<Utf8> Function(Pointer<Utf8>);

void main() {
  final lib = DynamicLibrary.open('${Directory.current.path}/zig/bxp-ffi/zig-out/lib/libbxp_ffi.so');
  final validateExpr = lib.lookup<NativeFunction<BxpValidateExprC>>('bxp_validate_expr').asFunction<BxpValidateExprDart>();
  
  final ptr = "Trading 212".toNativeUtf8();
  final resPtr = validateExpr(ptr);
  if (resPtr == nullptr) {
    print('Valid');
  } else {
    print('Error: ${resPtr.toDartString()}');
  }
}
