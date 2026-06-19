# VocaFlow Flutter

Flutter로 새로 만든 VocaFlow 단어 학습 앱입니다.

## 기능

- 오늘의 학습 현황과 연속 학습일
- 여러 세션을 선택해 한 번에 합쳐서 학습
- 세션별 이름과 단어 수 편집
- 탭하거나 위/아래로 스와이프하는 카드 학습
- 직접 뜻을 입력하는 타이핑 퀴즈
- CSV 단어장 가져오기 및 단어장 선택/삭제
- 단어장별 세션 탐색과 개별 단어 편집
- 세션 단어 수와 D-day 설정
- `SharedPreferences` 기반 로컬 학습 기록

## 실행

Flutter SDK를 설치한 뒤 이 폴더에서 실행합니다.

```powershell
flutter create --platforms=android,ios .
flutter pub get
flutter run
```

CSV 열 순서는 `term,meaning,reading,example,exampleMeaning`이며 뒤의 두 열은 선택입니다.

## Firebase

현재 버전은 계정 없이 완전히 동작하는 로컬 우선 앱입니다. Google 로그인과
클라우드 동기화는 Firebase 프로젝트의 `google-services.json`,
`GoogleService-Info.plist`, FlutterFire 설정이 준비된 뒤 연결해야 합니다.
