# Contributing

Thanks for wanting to help. The most useful thing right now is testing on a real table: run a scan, measure the balls with a ruler, and share the `cuesight-bench compare` output in an issue. Bug reports and small pull requests are welcome too.

Before you send a change:

1. Run `cd CueSightKit && swift test`.
2. Run `scripts/privacy_check.sh`. Camera frames stay on the phone, and the app has no networking.
3. Keep each pull request small and about one thing.

## Licensing of contributions

CueSight is under the PolyForm Noncommercial License 1.0.0, and its author keeps the right to use it commercially. So a contribution can only be accepted if you agree that Abozar Alizadeh may use, change and relicense it under any terms, commercial ones included. Opening a pull request means you agree to that, and that the work is yours to give. If you can't agree, please open an issue to describe the idea instead.

Any third-party code or assets you add must keep their own licence. Say what it is in the pull request, and don't add anything under AGPL or GPL.
