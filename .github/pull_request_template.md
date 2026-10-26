<!--
기여 안내 / Contributing: CONTRIBUTING.md · CONTRIBUTING.en.md
모든 PR은 `accepted` 라벨이 붙은 이슈에서 시작합니다. / Every PR starts from an issue labeled `accepted`.
-->

Closes #<!-- 이슈 번호 (필수) / issue number (required) -->

## 바뀐 것 / What changed

<!-- 무엇이 어떻게 동작하게 되었는지, 친 키와 결과의 예와 함께 -->
<!-- What works now and how, with keys and results -->

## 확인한 것 / How it was checked

- [ ] `swift test`
- [ ] `scripts/install.sh`로 설치하고 실제로 입력해 봄 / installed with `scripts/install.sh` and typed for real (앱 / apps: )
- [ ] 판단·분리를 바꿨다면 eval.tsv, en_50k 등에서 잘못 분리된 단어가 늘지 않음, 전후 숫자를 아래에 / if decisions or splits changed: no new wrong splits in eval.tsv, en_50k…, numbers below
- [ ] `InputSession`·`ArasoService`를 바꿨다면 `swift test --filter ServiceTests`, Windows CI / if `InputSession` or `ArasoService` changed: ServiceTests and the Windows CI
- [ ] 사용자에게 보이는 동작을 바꿨다면 README.md와 README.en.md를 함께 고침 / if users see the change: README.md and README.en.md both updated
