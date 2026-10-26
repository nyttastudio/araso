# Araso에 기여하기

[English](CONTRIBUTING.en.md)

버그 신고, 판단이 틀린 단어 사례, 코드 모두 환영합니다. 리뷰는 메인테이너 한 명이 하므로 답이 늦을 수
있습니다.

## 시작하기 전에

**모든 PR은 이슈에서 시작합니다.** 이슈 없이 온 PR은 이슈가 생길 때까지 리뷰하지 않습니다.

1. [이슈](https://github.com/nyttastudio/araso/issues/new/choose)를 먼저 엽니다. 버그는 버그 양식에,
   새 기능이나 개선은 제안 양식에 적어 주세요.
2. 메인테이너가 이슈에서 방향에 답하고 `accepted` 라벨을 붙이면 작업을 시작합니다. 버그도,
   새 기능도, 문서 수정도 같습니다. 크게 만든 뒤에 방향이 달라지면 서로 수고가 크기 때문입니다.
3. PR 설명에 `Closes #번호`로 이슈를 연결합니다. `accepted` 이슈에 연결되지 않은 PR에는 봇이 안내
   댓글을 달고, 연결되면 그 댓글을 고쳐 알려 줍니다.

질문, 설치 문제, 보안 문제는 이슈가 아닌 곳으로 보내 주세요.

- **질문이나 설치 문제**는 [Discussions](https://github.com/nyttastudio/araso/discussions)에 올려
  주세요.
- **보안 문제**(입력한 글자가 새어 나가는 경로 등)는 공개 이슈 말고
  [비공개 신고](https://github.com/nyttastudio/araso/security/advisories/new)로 알려 주세요.

포크와 다른 플랫폼 포팅은 자유지만, 공식 버전과 헷갈리지 않도록 Araso라는 이름으로 배포하지 말아
주세요.

## 준비

- macOS, **Xcode 26 이상**(Swift 6.2 이상). Xcode 16(Swift 6.1)으로는 빌드되지 않습니다. CI는
  `macos-latest`에서 돕니다.
- 정확도 평가 도구에는 `python3`만 있으면 됩니다(추가 패키지 없음).
- Windows 쪽은 [docs/windows-port.md](docs/windows-port.md)를 보세요. Windows에서만 도는 코드는
  맥에서 실행할 수 없고, PR의 Windows CI가 빌드와 테스트를 맡습니다. C++ 컴파일만 확인하려면
  `windows/scripts/check-cross.sh`(zig)를 쓰세요.

처음 보는 용어(늦게 뗀 Shift, 단어, 읽기…)는 [GLOSSARY.md](GLOSSARY.md)에 있습니다. 코드 구조와
주의할 점은 [AGENTS.md](AGENTS.md)에 가장 자세히 정리되어 있습니다. AI 에이전트용으로 쓴 문서지만
사람이 읽어도 됩니다.

## 빌드와 테스트

```sh
swift build
swift test                                   # 전부 (Swift Testing, 몇 초)
swift test --filter MixedWordTests           # 스위트 하나
swift run araso-cli -v "dkssud hello"        # 영어/한국어 판단과 점수
```

입력 로직은 모두 `Sources/ArasoCore`에 있고 테스트도 대부분 이곳을 다룹니다. `InputSession`은
`FakeTextField`로 테스트합니다. `InputSession`을 바꿨다면 Windows에도 반영되니
`swift test --filter ServiceTests`도 확인하세요.

## 실제 입력으로 확인하기

테스트만으로는 부족합니다. CLI에서는 맞아 보였지만 실제 입력에는 반영되지 않은 분리 규칙도
있었습니다.

```sh
scripts/install.sh                           # 릴리스 빌드, 자체 점검, ~/Library/Input Methods에 설치
/usr/bin/log show --last 10m --predicate 'subsystem == "com.nyttastudio.inputmethod.Araso"' --info --debug
```

- 바뀐 코드는 `scripts/install.sh`로 설치해야 실제 입력에 반영됩니다. `open`이나 `build/`에서 실행한
  사본은 입력기 연결을 받지 못합니다.
- **서명:** 키체인에 Apple Development 인증서가 있으면(무료 Apple 계정으로도 Xcode에서 만들 수 있음)
  재설치 뒤 Araso가 저절로 다시 실행됩니다. 인증서 없이 ad hoc으로 서명하면 재설치할 때마다
  **시스템 설정 → 키보드 → 입력 소스 → 편집…**에서 Araso를 지웠다가(−) 다시 추가(+)해야 합니다.
- 공식 pkg로 설치한 사본(`/Library/Input Methods`)과 섞어 쓰지 마세요. pkg 사본을 먼저 제거한 뒤에
  `install.sh`를 쓰세요.
- `log` 대신 `/usr/bin/log`를 쓰세요. zsh의 내장 `log`가 가려서 아무것도 출력하지 않습니다.
- `scripts/typing-test/run.sh`는 약 1분 동안 키보드와 포인터를 가져갑니다. 그동안 맥을 쓰지 마세요.

## 판단 규칙을 바꿀 때

영어·한국어·일본어 판단이나 단어 분리를 고치면 원래 고치려던 사례만이 아니라 **잘못 분리되는
단어가 늘지 않았는지**도 확인해야 합니다.

```sh
tools/prepare.sh                             # 처음 한 번 평가 데이터를 tools/data에 받음 (gitignore됨)
```

- `tools/data/eval.tsv`의 모든 행(영어, 한국어, 일본어)을 일본어를 켠 `InputSession`으로 쳐 보고,
  한글과 가나가 붙어 나온 경우를 세어 보세요.
- 영어는 `tools/data/en_50k.txt`도 `araso-cli -v`로 돌려 보세요.
- 영어 + 조사는 `tools/eval_particles.py`를, URL과 경로는 `tools/eval_urls.py`를 쓰세요.
- 사전 단어 + 조사를 바꿨다면 `DictionarySplitCheckTests`를 돌리세요. worktree에서는
  `ARASO_TOOLS_DATA=<메인 체크아웃>/tools/data`가 필요합니다.
- 잘못된 분리는 그 사례만을 위한 규칙을 추가하지 말고, 점수(`Weights`)나 단어 목록으로 고쳐 주세요.

PR 설명에 바꾸기 전후의 숫자(정확도, 잘못 분리된 단어 수)를 적어 주세요.

## 지켜야 할 것

- **친 글자를 로그에 남기지 않습니다.** 키 종류와 앱 이름만 기록합니다.
- 사용자에게 보이는 동작을 바꿨다면 **README.md와 README.en.md를 같이** 고쳐 주세요.
- UI 문자열은 `L("English key")`를 거치고, 한국어 번역은 `Resources/ko.lproj/Localizable.strings`에
  넣습니다.
- `Sources/ArasoCore/Data`에 새 데이터 파일을 추가했다면 `scripts/build-app.sh`에도 추가해야 앱에
  복사됩니다.
- 앱별 설정(`apps.json`)에 기본으로 들어가는 앱 목록은 없습니다. 특정 앱을 위한 기본값을 추가하지
  마세요.

## 커밋과 PR

- 한 PR에는 한 가지 변경만 담아 주세요.
- 커밋 메시지는 무엇이 어떻게 동작하게 되는지 한 문장으로 씁니다(`git log` 참고). 영어를 권하지만
  한국어도 괜찮습니다. PR 제목과 설명은 한국어나 영어 어느 쪽이든 괜찮습니다.
- main은 선형 히스토리만 받습니다(squash 또는 rebase로 머지). 브랜치를 최신으로 맞출 때는 main을
  머지하지 말고 rebase 해 주세요.
- 처음 PR을 보내면 CI는 메인테이너가 승인한 뒤에 돕니다.
- CI(`test`)가 통과해야 머지됩니다. `InputSession`이나 `ArasoService`를 건드렸다면 Windows CI도
  확인해 주세요.
- AI 도구를 써도 괜찮습니다. 이 저장소의 [AGENTS.md](AGENTS.md)를 읽게 하세요(Claude Code는
  CLAUDE.md를 거쳐 읽습니다). PR에는 직접 실행하고 확인한 결과를 적어 주세요.

## 라이선스

보내 주신 기여는 이 프로젝트와 같은 [MIT 라이선스](LICENSE)로 배포됩니다.
