---
name: one conformance feature for every stack
description: How the TaskBox contract's conformance scenarios are turned into tests that every stack realization runs
problem: The TaskBox contract lists its conformance scenarios in prose; each stack must prove its realization against them — should each stack write its own tests from the prose, or run one shared executable form?
decision: The scenarios are one Gherkin feature with a fixed step vocabulary, kept in solution-taskbox's Implementation, copied verbatim into every stack, and run once per store the stack supports.
---

# Problem
The TaskBox contract (VP-C003) promises that a service rewritten in another stack keeps its tasks and their behaviour. Its §8 names the scenarios that prove a realization conforms. Every stack already tests with Cucumber ([solution-conformance-testing](https://github.com/InsonusK/ai-skills/blob/develop/skills/common-workflow/test/solution-conformance-testing.skill/solution-conformance-testing.skill.md)). The question is who writes the scenarios.

# Selected variant
[One shared feature file (selected)](#one-shared-feature-file-selected)

# Searched variants

## One shared feature file (selected)

### Description
`taskbox-conformance.feature` lives in this solution's `Implementation/` together with the step vocabulary. Every stack copies it verbatim and implements the steps against its stores; `@store-persistent` / `@store-transient` tags mark the only store-specific scenarios.

### Benefits
- "Conforms" means the same executable text passed in every stack; nothing is lost in translation from prose.
- A scenario fixed or added once reaches every stack by the copy check.
- Expected values stay in the feature file, as `cucmber-testing` requires.

### Costs
- Every stack implements a whole step vocabulary (≈20 steps), including time-based ones.
- The steps must stay store-agnostic, so a store-specific detail (Redis partitions) appears as a setting that the other stores ignore.

## Each stack writes its own tests from §8

### Description
The contract's prose is the only shared form; each stack writes scenarios or plain tests in its own words.

### Benefits
- Each stack picks the test form that suits it.

### Costs
- Stacks drift: a hard scenario gets weakened or skipped in one stack and nobody notices.
- The same behaviour is specified N times.

## A shared black-box test service

### Description
One test program, in one language, drives any realization over a small HTTP test API that each stack exposes.

### Benefits
- The scenario code is written once.

### Costs
- Every stack must build and expose a test API; enqueue inside the caller's transaction cannot be driven from outside the process.
- Adds a second language and runtime to every stack's test run.
