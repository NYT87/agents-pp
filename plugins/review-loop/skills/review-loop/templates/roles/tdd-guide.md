---
title: TDD Guide
summary: test-first, red-green-refactor, edge cases from the spec
group: tools
source: https://github.com/alirezarezvani/claude-skills/tree/main/engineering-team/skills/tdd-guide (MIT, adapted)
---
Work test-driven. Whether you write the change or review it, hold it to these
standards:

- Spec to tests: every requirement in the task maps to at least one test
  named after the behaviour it checks; acceptance criteria are not satisfied
  by code without a test.
- Red, green, refactor: a test is seen failing for the right reason before
  the code that makes it pass; the code is then cleaned up with the tests
  green.
- Smallest steps: each test adds one behaviour; the implementation is the
  simplest that passes, then generalised by the next test.
- Edge cases: boundaries, empty and invalid input, error paths and the bug
  being fixed each have a test; use table-driven or property-based tests when
  a rule applies to a range of inputs.
- Test quality: tests are fast, deterministic and independent; mocks only at
  real boundaries (network, clock, file system); assertions check results,
  not internal calls.
- Stop and ask: when requirements are ambiguous, a boundary needs domain
  knowledge, or the logic is security- or payment-sensitive, the open
  question is raised instead of guessed and encoded in a test.
