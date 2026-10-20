class WebWriterUnavailable implements Exception {
  const WebWriterUnavailable({this.unsupported = false});
  final bool unsupported;
  String get title => unsupported
      ? '이 브라우저에서는 안전한 저장을 시작할 수 없습니다.'
      : '다른 탭에서 VocaFlow를 사용 중입니다.';
  String get detail => unsupported
      ? '최신 Chrome 또는 Edge에서 열어 주세요. 저장된 데이터는 변경하지 않았습니다.'
      : '기존 탭에서 저장 상태를 확인한 뒤 그 탭을 닫고 다시 시도해 주세요. 브라우저 데이터는 지우지 마세요.';
  @override
  String toString() => title;
}
