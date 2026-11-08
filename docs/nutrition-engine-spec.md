# Deterministic nutrition engine — corrected contract

Status: draft v2 · 2026-11-08. Companion to app-spec.md draft v3.
Supersedes the v1 research draft, preserved as nutrition-engine-spec-v1-research.md.
The review in nutrition-engine-review.md describes v1, not this revision.

This is a domain and implementation contract, not clinical validation or working
application code. Planning and coaching remain core offline features. AI is only
an optional input, command-interpretation, and explanation layer.
ChatGPT-powered label OCR and meal-photo assistance remain supported optional
inputs through the app's provider adapter; each produces a reviewed draft. A
custom on-device food vision model remains deferred to later research.

## 1. Authority, evidence, and release status

- This file owns nutrition semantics, calculation contracts, policy behavior, and
  algorithm acceptance tests. app-spec.md owns product, storage, integration,
  privacy, and delivery requirements. Neither silently overrides the other.
- [G] = published guideline/reference for a named population. [R] = research in
  a specified population. [P] = engineering/product choice requiring evaluation.
- Citing the ingredients of a custom algorithm does not validate the composition.
- Reference comparisons are not diagnoses. Targets are user-selected or
  policy-generated plans, not measurements of an individual's requirements.
- Stable domain contracts below are approved for implementation as a draft.
  Numerical product defaults marked [P] are candidates, not validated health rules.
- Initial automatic targets require a reviewed, versioned EligibilityPolicy and
  TargetPolicy bundled with the app. Until approved, development builds return
  POLICY_NOT_APPROVED rather than issuing purportedly safe recommendations.
- Adaptive calorie proposals have an additional experiment gate: disabled for
  ordinary users until algorithm-specific simulations, review, and prospective
  evaluation support their intended scope. No remote inference enables this gate.
- Logging, recipe arithmetic, planning against a declared target, and non-adaptive
  coaching do not depend on promoting an experimental expenditure estimator.

## 2. Deterministic application services

```text
record/revise intake -> calculate reported nutrition -> observe patterns
              |                      |                       |
          saved foods         reference comparisons     weekly check-in
              |                      |                       |
recipe definitions + batches -> meal planner -> grocery list / plan repair
                                     |
                          user confirms actual consumption
```

Services: FoodCalculationService, ReferenceComparisonService, EligibilityService,
TargetService, WeightObservationService, PlannerService, CoachingService.
An ExperimentalAdaptationService can propose changes; it cannot write a target.
All writes use ordinary validated commands, snapshot revisions, and confirmation.

## 3. Eligibility and safety — one policy, separate permissions

### 3.1 Intended scope

The initial self-service recommendation scope is generally healthy,
nonpregnant, nonbreastfeeding adults. A declaration is not a medical assessment.
The approved policy must specify age range, relevant medication/condition routes,
weight-goal restrictions, and referral copy. Do not preserve v1's unsupported
65/75-year or BMI-35 cutoffs as guideline-derived facts.

Ask only necessary, editable questions. Unknown answers do not certify eligibility.
Equation inputs, sex-specific reference categories, gender identity, menstrual
status, and pregnancy are different fields; never infer one from another.
If an appropriate equation/reference category cannot be selected, offer a
user-declared target or neutral logging rather than an invented physiological input.

### 3.2 Permission model

```text
EligibilityDecision {
  policy_version, reason_codes,
  recording: allowed,
  reference_display: generic | matched_profile | hidden_by_preference,
  planning: organization_only | declared_targets | approved_auto_targets,
  initial_target_generation: allowed | blocked | needs_review,
  adaptive_proposals: allowed | blocked | experimental_only,
  weight_display: ordinary | user_controlled_support_mode,
  signposting: none | qualified_advice | urgent_help
}
```

- Minors and pregnancy/breastfeeding: no automatic energy targets or adaptation
  in this initial adult scope; do not apply ordinary adult references as personal
  adequacy criteria. Food organization/recording can remain available.
- Medical nutrition needs, eating-disorder concerns, or relevant medicines:
  route to qualified advice and block unsupported automatic energy advice.
  Basic arithmetic remains available with reviewed support-mode presentation.
- Strict food allergy/coeliac requirements are enforced in planning independently
  of energy eligibility. A declared need for clinical dietary management also
  blocks ordinary automatic energy advice; there is no contradictory exception
  in examples. Planning is not certification of clinical suitability.
- A user-declared or clinician-provided target can be recorded with its origin.
  It is not automatically certified by the app; applicable safeguards still apply.
- 'Organization only' means recipes, schedule, portions, and groceries without
  generating energy goals or claiming nutritional adequacy. Do not label this
  undefined state 'maintenance/adequacy mode'.
- Support mode defaults to hiding calorie-budget pressure, weight/BMI graphs,
  deficit prompts, and outcome streaks; user controls and wording require review.
  Do not imply that numeric logging is universally safe for everyone with ED history.

### 3.3 Safety evaluation is independent of data sufficiency

Run declared-condition/symptom routing before deciding whether an estimator may
run. Sparse logs cannot suppress a safety flag. Safety outputs can suspend energy
recommendations and signpost care; they do not prescribe an uncapped calorie
increase or diagnose the cause of weight change.

An unexplained rapid change is not automatically 'water, not fat'. Describe the
observation and its limitations. Urgent-symptom wording and thresholds must be
reviewed clinical content, not free-form AI triage.

If advice is suspended: preserve records and the prior target for audit, mark the
target inactive for recommendation/budget nudges, and do not install a replacement
'maintenance' prescription. User-approved manual targets use the normal policy.

## 4. Food quantities and nutrient observations

### 4.1 Quantities retain their actual basis

```text
FoodQuantity { value_decimal, unit: g | ml | item | serving, measure_id? }
NutritionBasis { quantity: FoodQuantity, preparation_state, edible_basis }
NutrientObservation {
  nutrient_id, amount_decimal?, unit, basis,
  qualifier: reported | reported_zero | below_detection | trace | estimated | unknown,
  origin: label | analytical_reference | ingredient_calculation | user_entry | imputation,
  definition_id, source_id, source_version, evidence_date?,
  supplied_interval?: {lower?, upper?, inclusivity, scope, method}
}
```

- Store source-declared per-100-g, per-100-ml, per-serving, or per-item values.
  Scaling within the same basis does not require density. Convert ml to g only
  with a food-specific conversion and provenance.
- Store both printed kJ and kcal when supplied. Derive a missing unit with the
  conversion recorded; never replace a supplied value solely to force agreement.
- EU available carbohydrate, US total carbohydrate, fibre, polyols, total sugars,
  added sugars, and free sugars are distinct definitions. Import adapters must
  preserve and normalize only supported transformations. No double-subtracting fibre.
- EU declared carbohydrate excludes fibre and includes polyols; source energy
  calculations must treat their distinct energy factors correctly. [G1]
- A printed zero is reported_zero, not proof of exact analytical absence. Preserve
  rounding/detection information when available; do not invent an interval.
- An omitted nutrient stays unknown. A model guess or borrowed reference stays
  estimated; neither becomes verified because it was user-reviewed.
- Separate foods in materially different preparation states. Raw-to-cooked record
  matching is not an arbitrary universal weight multiplier.

### 4.2 Dimensionally explicit arithmetic

For an observation of `a` nutrient units per basis quantity `b`, and a compatible
consumed quantity `q` in the same unit:

```text
recorded_amount = a * q / b
example: 12 g protein per 100 g food * 150 g / 100 g = 18 g protein
example: 40 kcal per 100 ml * 250 ml / 100 ml = 100 kcal, no density needed
```

A day total sums compatible recorded observations. Arithmetic is deterministic;
input variability, rounding, omitted foods, and incorrect food matches remain.
Do not call the reported sum a guaranteed lower bound on actual intake.

Derived-energy checks use definition-specific factors and subtract overlapping
components before applying factors. EU factors include carbohydrate except
polyols 4 kcal/g, protein 4, fat 9, fibre 2, polyols 2.4, erythritol 0, alcohol 7,
and organic acids 3. Preserve source energy as primary for logs. [G1]
A disagreement produces a provenance/definition-aware validation warning, not an
automatic rewrite. Warning tolerances are versioned import rules, not a universal
20% physiological accuracy guarantee.

### 4.3 Aggregation and completeness

```text
NutrientSummary {
  nutrient_id, recorded_sum?, unit,
  known_entries, missing_entries, estimated_entries, affected_food_ids,
  record_completeness: complete_for_record | partial | no_data,
  diary_completeness: user_declared_complete | partial | unknown | confirmed_no_intake,
  estimated_contribution?, source_supplied_interval?, scope
}
```

For an entirely unknown nutrient, recorded_sum is absent, not zero. For a partial
record, display 'recorded amount; missing for these foods', not a bare total.
Known-zero records can produce a reported zero, with source limitations intact.

- No catalogue percentile is a hard upper bound.
- No mass-weighted coverage percentage certifies nutrient completeness. Optional
  mass/item statistics are descriptive only; water cannot authorize a nutrient verdict.
- Source intervals describe their documented scope; they are not automatically
  intervals for actual intake. Any imputation/model interval is separately labeled
  and requires calibration for its claimed interpretation.
- The baseline engine does not impute missing nutrient amounts for coaching.
- Food-only, supplements, and combined totals are separately available. A missing
  supplement log does not establish that no supplements were taken.

### 4.4 Snapshots and revisions

Freeze quantity, observations, conversions, recipe/batch identity, source versions,
and engine/policy versions at intake commitment. Catalogue changes do not rewrite
history. An explicit correction creates a revision; any derived result whose
input revision changes is invalidated, regardless of how recent the edit is.
Record the diary date and original time/zone separately from current display zone.

## 5. Recipes, cooked batches, and groceries

```text
RecipeVersion { immutable ingredient definitions, preparation, serving convention }
PlannedBatch { recipe_version, planned_scale, expected_yield?, planned_allocations }
CookedBatch { recipe_version, actual_ingredients, finished_weight_g?, created_at,
              storage_metadata?, available_amount, revision }
PortionAllocation { batch_id, day_or_intake_id, amount, unit, status }
```

A RecipeVersion is not inventory. Multiple actual batches may share its definition.

- Enter the edible quantities actually measured. Gross weight needs a recorded
  edible fraction; absent that, ask for edible weight or an explicitly estimated
  conversion. Do not silently count skin/bone as eaten.
- Ingredient total for nutrient `n`: `sum(amount_per_basis_i * edible_q_i / basis_q_i)`.
- Per-100-g batch concentration: `100 * batch_total_n / finished_weight_g`.
- Equal serving: `batch_total_n / serving_count`; this can work without finished
  weight when ingredient quantities and equal-serving assumptions are explicit.
- Without measured/sourced finished yield, do not offer precise gram-based logging
  from summed raw weights as if cooking did not change water content.
- Optional retention tables/discarded ingredients require method/source metadata.
  Without them, disclose that micronutrient/cooking losses are not modeled.
- Partial ingredient data produces partial recipe summaries with missing ingredient
  provenance, not a falsely complete vector.
- An ingredient/yield revision affects new batches or explicitly revised batches,
  not historical intake. Allocations cannot exceed confirmed available stock.
- Leftovers cross calendar weeks. Storage/safety recommendations require a separate
  reviewed policy; the app never guarantees a batch remains safe to eat.

Groceries aggregate ingredients in purchase-compatible states and units. Link
cooked requirements to raw purchase quantities only through a supported recipe
conversion. Pantry quantities are confirmed, estimated, or unknown; subtract only
under an explicit rule, and show estimates. Preserve manual shopping-list entries,
purchase checkmarks, and user edits through plan repair. No fictional density or
silent 'as needed' quantity for a nutritionally unresolved ingredient.

## 6. Nutrient reference and target policy

### 6.1 Typed references

```text
ReferencePolicy {
  nutrient_id, definition_id, population_match, source, edition, review_date,
  kind: PRI | AI | AR | RI_RANGE | MAXIMUM_GUIDANCE | UL | SAFE_INTAKE_LEVEL | USER_TARGET,
  value_or_range, unit, intake_scope, temporal_basis,
  comparator_direction, policy_status
}
```

Population reference intakes are not measurements of personal requirements.
An AI is not equivalent to a threshold below which inadequacy is established.
A UL is not a target. A safe intake level is not an identified adverse-risk cutoff.
EU label reference intakes and physiological dietary references are separate
reference systems; never substitute the printed 2,000-kcal label basis for a
personal calorie target. [G1, G2]

### 6.2 General-adult reference set

These anchor the proposed general-wellness implementation, not a clinical diet.
Import the full selected reference tables with correct populations/forms; the
following are not a promise that every food has these fields.

| Field | Reference and interpretation | Basis |
|---|---|---|
| Protein | 0.83 g/kg/day PRI, not a personal measured minimum | [G2] EFSA |
| Total fat | 20–35% energy reference range | [G2] EFSA |
| Carbohydrate | 45–60% energy reference range, source definition retained | [G2] EFSA |
| Fibre | 25 g/day AI for adults | [G2] EFSA |
| Sodium | 2 g/day safe/adequate EFSA reference; separately WHO guidance to limit sodium below 2 g/day, equivalent to 5 g salt | [G3, G4] |
| Saturated fat | no more than 10% energy as WHO guidance, not an EFSA numeric UL | [G4] |
| Free sugars | below 10% energy as WHO guidance; total sugars cannot stand in for this field | [G4] |

Store/allow inspection of other supported vitamins, minerals, and constituents;
use a small user-configurable default dashboard, not a permanent eight-nutrient
schema limit. Micronutrient comparisons require the correct age/life-stage/reference
form and adequate record data. For iron, capture relevant reference-category inputs
rather than inferring menstruation from age or gender. Folate forms and supplement-
only limits need separate fields/scopes.

Iron example: EFSA's 40 mg/day adult value is SAFE_INTAKE_LEVEL, **not a UL**.
Do not issue an 'above toxicity threshold' message merely for exceeding it. [G5]
No other old UL number is carried into a release policy without current verification.

Food-pattern guidance uses Portugal's Roda/Mediterranean guidance as a source for
portion definitions, variety, and food choices. Its broad portion ranges are not
one individualized prescription; do not score every adult against the full ranges
as if needs were identical. Produce separate, explainable pattern observations
rather than a universal health grade. [G6]

### 6.3 Comparison results

```text
ComparisonResult = recorded_below_reference | recorded_at_or_above_reference
                 | recorded_within_range | recorded_outside_range
                 | recorded_above_guidance | recorded_not_above_guidance
                 | insufficient_data | reference_not_applicable
```

- Results explicitly concern records, not diagnosed status or confirmed actual intake.
- Require compatible nutrient definitions, units, intake scope, temporal basis,
  applicable reference, and record/diary completeness for an unqualified recorded
  comparison. Missing/estimated decisive data gives insufficient_data.
- An exception for excess observations: if even supplied contributions already
  exceed a maximum, a scoped 'recorded items already exceed guidance; other data
  are missing' observation is allowed. Do not claim it quantifies clinical risk.
- Do not issue low-intake coaching from a guessed upper bound or a low known sum
  with potentially decisive unknown contributions.
- With complete declared records, use multi-day patterns and reference-appropriate
  language. Falling below an AI/PRI in the log does not diagnose deficiency.

## 7. Initial calorie and macro targets

### 7.1 Target ownership

```text
Target {
  target_id, revision, effective_dates,
  energy_kcal?, macro_goals?, reference_policy_ids,
  origin: user_declared | clinician_provided | reviewed_policy_generated,
  formula_version?, policy_version, assumptions, review_status,
  planner_tolerance?, active_for_recommendations
}
```

A target, a planner tolerance, and statistical uncertainty are different objects.
Do not manufacture an individual ±10% confidence interval from population RMR
prediction studies. Display assumptions and lack of individual measurement.

### 7.2 Baseline candidate [P unless otherwise noted]

For eligible adult profiles under an approved local policy, use Mifflin–St Jeor:

```text
RMR_kcal_day = 10*weight_kg + 6.25*height_cm - 5*age_years + equation_constant
constant = +5 or -161 under the equation's applicable sex-specific branch
baseline_energy = RMR_kcal_day * chosen_PAL
```

This is a prediction, not calorimetry. Candidate PAL options are 1.4, 1.6, 1.8,
and 2.0 (EFSA energy-framework values; mapping questionnaire answers to them is
[P]). The selected habitual activity level includes ordinary structured exercise.
Do not systematically choose the lower category when uncertain; ask, display a
range of scenarios, or request a declared target. [G2]

Candidate initial offsets: maintain 0%, cut -10%, gain +5% of baseline energy [P].
These replace v1's weight-rate-to-7,700 conversion as the default target policy.
They are starting design candidates, not universal prescriptions or promised
weight-change rates. Approved policy must define eligibility, intake/deficit
screens, and refusal alternatives before these offsets reach ordinary users.

No universal RMR floor, inherited sex-specific 1,200/1,500 floor, or BMI-only proof
of safety is specified. NICE defines 800–1,200-kcal low-energy diets within supported
services; that fact does not establish our personalized self-service cutoffs. [G7]
Underweight users seeking loss are outside automatic deficit advice; clinical
population rules must not be extrapolated from a single BMI classification.

### 7.3 Macro allocation candidate [P]

Keep reference comparisons and selected performance goals distinct. A candidate
wellness allocation is protein `max(0.83*weight_kg, 0.15*energy_kcal/4)` g/day and
fat at 30% energy, with carbohydrate as the remaining allocation. Its numeric
allocation is [P], not an EFSA-mandated split. A resistance-training preset can
propose 1.6 g/kg/day protein for its reviewed intended population; this is a
performance objective informed by resistance-training evidence, not a universal
minimum or maximum, and not a BMI-based fat-free-mass estimate. [R1]

For the EU available-carbohydrate allocation convention, explicitly budget fibre
energy (candidate: 25 g * 2 kcal/g) and any other chosen energy contributions:

```text
protein_energy = 4 * protein_goal_g
fat_energy = chosen_fat_fraction * target_energy
carb_goal_g = (target_energy - protein_energy - fat_energy
               - allocated_fibre_energy - other_allocated_energy) / 4
```

This is a planning allocation, not a replacement for source energy arithmetic.
Actual food totals determine plan energy. Avoid forcing all nutrient grams and
label energy into a spurious exact 4/9/4 identity.

If goals do not fit: return TARGET_CONFLICT with the conflicting constraints and
choices (reconsider a performance goal, energy target, or macro preference).
Never emit negative carbohydrate grams or install a flagged impossible target.
The 130-g carbohydrate RDA is reference context, not a universal physiological
minimum. Do not silently prioritize an optional sports goal over all other needs.

```text
generateTarget(profile, request, policy):
  eligibility = evaluateEligibility(profile, policy)
  if not policy.approved: return POLICY_NOT_APPROVED
  if not eligibility.initial_target_generation.allowed: return BLOCKED(reason)
  estimate = baselineForApplicableEquation(profile)
  draft = allocateMacros(applyApprovedGoalPolicy(estimate, request), policy)
  if conflicts(draft): return TARGET_CONFLICT(details, alternatives)
  if not passesApprovedScreens(draft, profile): return REFUSED(reason, alternatives)
  return TARGET_PROPOSAL(draft, assumptions, requires_confirmation=true)
```

## 8. Weight observations and adaptive recommendations

### 8.1 Production observations

Store measured weight separately from trend estimates and goals. Deduplicate
imports by origin and identifiers. Use timestamps for irregular measurements;
make graph smoothing independent of adherence to calorie targets. A display
smoother's numeric alpha/window is a versioned UI parameter [P], not evidence of
individual physiological precision. Do not describe scale change as measured fat loss.

Diary-day states: unknown, partial, user_declared_complete, confirmed_no_intake.
Never infer completeness from meal count or a calorie threshold. A confirmation
is an explicit report, not an accuracy certificate. Approximate entries can still
be user-declared complete; preserve their estimation provenance.

### 8.2 Experimental estimator contract

The old selected-day-mean formula, percentile-derived precision, fixed ±15%
onboarding anchor, and borrowed eight-weigh-in rule are retired, not grandfathered.

A candidate EstimatorPolicy must define:

- Quantity estimated: actual TEE, change in energy intake, or a logged-intake target
  correction. Do not interchange these outputs or validate one using another's study.
- The precise input interval and aligned energy/weight evidence. Do not subtract
  a full-period weight slope from an unrepresentative complete-day intake mean.
- Missing-day policy. Baseline prototype abstains on unaccounted intake days in
  the chosen interval; alternatives need an explicit latent/missing-data model
  and selection-bias evaluation. Never fill unknown days with zero or quietly
  assume skipped weekends resemble weekdays.
- Required observation duration, spacing, logging consistency, transition handling,
  and contextual pauses. These are model-specific [P] settings, not universal facts.
- Which days are estimates, confirmed no-intake, or incomplete. Declared unusual
  periods and changes from estimated to weighed logging are independent inputs.
- Fit method, autocorrelation handling, outlier assumptions, validation corpus,
  uncertainty calibration, and sensitivity to water/glycogen/gut-content shifts.
- Limits on proposed changes, cooldown, deadband, baseline re-evaluation, and
  history invalidation, using typed kcal/day quantities.
- Evidence that any stated uncertainty applies to this method and population.

Hall–Chow (2011) informs caution about precision and longitudinal data. It does
not validate a different TEE estimator, sparse-weigh-in rule, fixed calorie
resolution floor, or our custom controller. [R2]

Consistent underreporting can yield a useful target calibrated to a logging habit
while biasing absolute expenditure. Changing reporting bias is particularly
important. A percent error in intake does not imply the same percent error in
TEE. Separate model uncertainty, logging bias, and controller policy.

### 8.3 Check-in contract and activation

```text
CheckInResult {
  window, input_revisions, policy_versions,
  observations[], data_quality, goal_progress?, adherence_summary?,
  safety_flags[], findings[],
  adaptation_status: disabled | experimental | insufficient_data | hold | proposal,
  target_proposal?: {old_revision, proposed_target, reason, assumptions, expiry}
}

weeklyCheckIn(profile, history, currentTarget, policies):
  safety = evaluateSafety(profile, history, policies.eligibility)
  observations = computeSupportedObservations(history)
  quality = describeDataQuality(history)
  findings = selectCoachingFindings(observations, quality, safety)
  result = report(observations, quality, findings, safety)
  if safety.blocksEnergyAdvice: return result.withAdaptation(DISABLED)
  if not policies.adaptation.approved: return result.withAdaptation(DISABLED)
  if not currentTarget.eligibleForProposals: return result.withAdaptation(DISABLED)
  if not sufficientForChosenModel(history): return result.withAdaptation(INSUFFICIENT_DATA)
  candidate = approvedEstimator(history, policies.adaptation)
  if not candidate.supported: return result.withAdaptation(HOLD)
  proposal = approvedBoundedController(candidate, currentTarget)
  if proposal.isHold: return result.withAdaptation(HOLD)
  if not passesApprovedScreens(proposal): return result.withAdaptation(HOLD)
  return result.withTargetProposal(proposal, requires_confirmation=true)
```

Safety is always evaluated, even when adaptation is unavailable. Safety suspension
never installs an automatic upward or downward target. Manual targets are sticky;
user approval is required to change them. Proposals are invalidated by changed
inputs, expired policy scope, or declined/accepted revision. Cooldown and adjustment
bounds must come from one shared policy object, not duplicated prose constants.

### 8.4 Acceptance gate

Compare candidates on simulated and held-out realistic histories: stable intake,
changing activity, gradual weight changes, reporting bias, incomplete weekends,
changes in weighing/logging practice, irregular measurements, and sustained water
shifts. Predefine error, lag, false-adjustment, uncertainty-coverage, abstention,
and harmful-restriction criteria. Record parameter versions and scope. Passing
unit tests is necessary but not clinical efficacy or safety validation.

## 9. Deterministic meal planning — core

### 9.1 Inputs and constraints

Inputs: declared/approved targets, household portions, meal schedule, recipe
catalogue, exclusions, available ingredients, time/equipment, preferences, pinned
meals, existing batches, and search policy version. If no energy target is
appropriate, organization-only planning remains usable without adequacy claims.

Immutable constraints: strict medical exclusions, explicit diet restrictions,
confirmed available batch inventory, and any approved safety restrictions.
Unknown status fails a strict allergen requirement. No ordinary 'accept unknown'
toggle bypasses strict allergy constraints. No cross-contamination or clinical
suitability guarantee is made.

User hard constraints: pinned meals, availability, required portion bounds,
explicit cooking-time limits, and any numerical target/tolerance the user chooses
to make binding. A range supplied as a hard constraint is enforced, not guessed.
Changing these requires a visible, accepted constraint revision. A pin conflicting
with a medical exclusion is reported as a conflict, never allowed to override it.

Soft objectives: nutritional target proximity, data completeness, fibre/food-group
variety, sodium/saturated-fat/free-sugar guidance, cooking effort, budget estimates,
reuse, preferences, and unwanted repetition. Meal buckets, energy-share splits,
and two-repeats-per-week rules are not universal safety constraints. Support the
user's own meal schedule and deliberate batch cooking.

Only use nutritionally resolved candidates for binding numeric nutrient checks.
Unknown sodium/free sugars do not become zero-cost foods. Partition numerical
quality from missing-data penalties; do not rank an unscorable candidate as
nutritionally better than an observed one.

### 9.2 Search and objective

Start with seeded construction plus bounded local search and reproducible ties.
The search budget and candidate/portion discretization are [P] operational settings.
Use staged priorities: immutable feasibility, other hard feasibility, preservation
of user pins/unchanged valid meals, then normalized nutritional/practical objectives.
Within numeric constraints, keep edible portion ranges and batch stock accounting.
Search heuristics are not proofs of optimality or global minimum-change repair.

```text
PlannerResult = VALID_PLAN(plan, validation, quality)
              | TARGET_CONFLICT(details)
              | INSUFFICIENT_DATA(missing)
              | SEARCH_EXHAUSTED(best_draft?, diagnostics)
              | PROVEN_INFEASIBLE(certificate, scope)
              | PROPOSED_RELAXATION(changes, preview?, validation)
```

PROVEN_INFEASIBLE requires a contradiction/empty eligible set certificate or a
complete feasibility method for the declared search space. Failure after 2,000
heuristic moves is SEARCH_EXHAUSTED, not proof no plan exists.

### 9.3 Validation and repair

```text
repairPlan(plan, context):
  original = searchUnderOriginalConstraints(plan, context)
  if original.valid: return VALID_PLAN(original)
  if original.missingDecisiveData: return INSUFFICIENT_DATA(details)
  diagnostics = explainOriginalSearch(original)
  options = proposeNonmedicalConstraintChanges(context, diagnostics)
  return options.nonempty
    ? PROPOSED_RELAXATION(options, original_status=diagnostics.status)
    : original.typedFailure

acceptRelaxation(change, expected_plan_revision):
  requireUserConfirmation(change)
  newContext = explicitConstraintRevision(change)
  return repairPlan(currentPlanAt(expected_plan_revision), newContext)
```

Never install a relaxed plan automatically. Validate every committed result:
all ingredient quantities/definitions resolved; all immutable/user-hard constraints
satisfied; recipe and batch revisions current; inventory not overallocated; numeric
checks use compatible data; every accepted relaxation recorded; plan remains
separate from consumption. Pins and unchanged valid meals are preserved as far
as the chosen search finds feasible; do not promise a globally optimal repair.

## 10. Deterministic coaching — core

Coaching is a local observation-and-action system, not a free-form nutritional oracle.

```text
Finding {
  rule_id, rule_version, applicable_population,
  window, input_revisions, evidence, limitations,
  action_type: hold | improve_data | edit_plan | discuss_target | seek_advice,
  action_payload?, priority, cooldown
}
```

- Evaluate safety routes independently and first. Maintain multiple observations;
  one numerical verdict lattice must not erase a safety flag or unrelated food insight.
- For ordinary coaching, default to one clearly prioritized actionable card per
  check-in [P], with other findings accessible. Safety messages are not suppressed
  by that content limit. Notification/cooldown values belong to versioned UX policy.
- Goal progress, target adherence, and record quality are separately computed.
  Reliable progress does not require obedience to the previous target.
- Pattern rules must declare window, denominators, evidence requirements, and
  definition compatibility. No hidden 70% mass-coverage authorization.

Initial rule families:

| Observation | Allowed local action | Important restriction |
|---|---|---|
| Missing/incomplete food days | Offer estimation, completion, or a logging break | No invented missing energy or automatic deficit |
| Repeated low recorded fibre on adequately declared days | Offer an eligible legume/whole-grain/vegetable swap | Compare recorded intake to reference, not diagnosed deficiency |
| Recorded sodium/saturated fat above guidance | Show known contributing foods and eligible alternatives | Missing nutrients remain visible; no claim the contributors explain all intake |
| Repeated plan deviations | Offer to simplify recipes, change portions, or revise preferences | Do not interpret deviation as failure or punish with lower targets |
| Limited variety in sufficiently logged meals | Offer an eligible food-group addition | No universal Roda score or required dairy for a vegan user |
| Weight trend observations | Describe the observed trend and whether data permit evaluation | No measured fat loss, cause attribution, or exact goal-date promise |
| Supported progress and practical plan | Positive hold-course card | No unnecessary target change to manufacture coaching value |
| Relevant symptoms/declared clinical needs | Suspend unsupported energy advice and signpost under policy | No diagnosis, medical reassurance, or automatic calorie prescription |

Recommendation candidates are validated by the same planner/reference/eligibility
services. AI can explain a finding, ask for a clarification, and invoke reviewed
commands. It cannot fabricate derived numbers or bypass a blocked recommendation.
No automatic supplements, medications, longer fasts, or claims of nutrient deficiency.

## 11. Worked domain example — not personal dietary advice

A user has a declared 2,000-kcal daily target. A saved product reports 10 g protein
per 100 g; logging 150 g contributes 15 g recorded protein. A separate drink
reports 40 kcal per 100 ml; 250 ml contributes 100 kcal without needing density.

A cooked recipe has 60 g recorded protein across ingredients and a measured
finished weight of 600 g. A 200-g allocation contributes 20 g recorded protein.
If iodine is unknown for one ingredient, recipe iodine remains partial; it is not
filled from a catalogue percentile or called a proven low intake.

The user plans 400 g of that batch tomorrow and 200 g later in the week. Another
200-g allocation would exceed this batch and is rejected or requires a new planned
batch. Changing the recipe next week does not alter these intake snapshots.

At check-in, fibre is reported as 19 g on several days but important foods lack
fibre data. The finding asks to improve those records, not 'you are below 25 g'.
If the declared days are adequately recorded instead, a scoped below-reference
finding can offer a planner-validated swap. Neither scenario diagnoses deficiency.

A changed lunch requests dinner repair while preserving pinned meals. Original
constraints are tried first. If a search budget expires, the app reports that it
could not find a plan within the budget; it does not assert impossible nutrition.
Any change to cooking time or energy tolerance is proposed for acceptance.

Missing weekend food records do not disappear into a weekday average. The
experimental estimator abstains under its baseline missing-day policy. Weekly
coaching, groceries, reference explanations, and manual target controls still work.

## 12. Acceptance tests and invariants

These are required tests for later implementation, not checks already executed.

### Recording and arithmetic

- Per-100-ml product logged in ml works without density; incompatible g/ml needs
  a conversion or clarification. Reported zeros remain distinguished from absence.
- EU/US carbohydrate imports preserve definitions and avoid double fibre subtraction.
- Both supplied kJ/kcal are preserved; derived missing units retain conversion provenance.
- Entirely missing nutrient -> no numeric total. Partially missing nutrient ->
  recorded partial sum and missing sources, not inferred actual-intake bounds.
- A tiny iodine-rich unknown ingredient plus much known water does not authorize
  an iodine-adequacy verdict. Fortified foods invalidate naive catalogue-percentile bounds.
- Exact decimal quantity scaling and recipe concentration follow explicit units;
  reference totals use the appropriate substance form and intake scope.

### Targets, safety, and coaching

- Safety flags survive sparse records, disabled adaptation, and user manual targets.
- Pregnancy/minor/clinical routes never substitute ordinary adult 'adequacy planning'.
- Coeliac/strict-allergy behavior is identical in policy, examples, UI, and tests.
- A BMI-only sports-protein branch does not exist. Impossible macro allocations
  return TARGET_CONFLICT, not negative grams or a usable flagged prescription.
- Unknown free sugars never inherit a total-sugars verdict. A safe level is never
  rendered as a UL. Low AI comparisons never diagnose inadequacy.
- Any prior-history revision invalidates dependent results; accepted/declined
  proposals cannot be replayed against a different target revision.
- Reported symptoms suspend unsupported energy advice, not increase calories by
  an unbounded amount. Support-mode displays/rewards follow the same policy.

### Experimental adaptation

- All 28 days stable weight; 20 weekdays 2,000 kcal, eight missing high-intake
  weekend days: no TEE from weekday mean plus full-period weight slope.
- Equal completeness before/after a switch to weighed portions does not certify
  unchanged reporting bias. Logging-method/context changes are separate evidence.
- No missing day becomes zero. Confirmed no intake is a distinct declared state.
- No borrowed ±10% individual confidence interval or universal 200-kcal resolution.
- Disabling adaptation leaves a complete offline non-adaptive coaching workflow.

### Planning and batches

- Six eligible dinner recipes, each allowed twice, can cover seven dinners; this
  must not be a fixture claiming inherent infeasibility.
- Impossible cases define a concrete catalogue/certificate (e.g. zero eligible
  recipes for a mandatory slot), not just 'vegan + high protein'.
- Original valid plan returns without any relaxation. Search exhaustion and
  insufficient data are distinct from certified infeasibility.
- Strict unknown-allergen candidate rejected; pins cannot override an exclusion.
- Missing sodium does not make a candidate automatically beat a measured candidate.
- Ingredient-resolution checks are enforced by the validator, not only by search.
- Unaccepted relaxation cannot become an active plan. User-hard revisions and
  accepted changes are versioned and revalidated.
- RecipeVersion cannot be used as unlimited leftover inventory. Cross-week batches
  preserve stock, units, and intake separation; overallocations are rejected.
- Same inputs, catalogue/policy versions, and seed produce reproducible results
  under the declared execution/numeric model. No claim of global optimization.

## 13. Evidence anchors and outstanding approval

These links anchor selected claims, not blanket approval of the implementation.
The v1 research archive contains a broader bibliography; unverified extrapolations
there are not carried forward by reference.

- [G1] EU Regulation 1169/2011, Annexes I/XIII/XIV: definitions, label reference
  intakes, and energy factors. https://eur-lex.europa.eu/eli/reg/2011/1169/oj/eng
- [G2] EFSA dietary reference framework and summary; maintain versioned population-
  and nutrient-specific entries rather than freezing every 2017 number forever.
  https://www.efsa.europa.eu/en/topics/topic/dietary-reference-values
  https://www.efsa.europa.eu/sites/default/files/2017_09_DRVs_summary_report.pdf
- [G3] EFSA sodium opinion (2019): safe/adequate intake is distinct from a UL.
  https://doi.org/10.2903/j.efsa.2019.5778
- [G4] WHO healthy-diet guidance: sodium, fat quality, free sugars, fibre, and
  food patterns. https://www.who.int/news-room/fact-sheets/detail/healthy-diet
- [G5] EFSA iron assessment: no UL established; adult safe intake level 40 mg/day.
  https://www.efsa.europa.eu/en/plain-language-summary/scientific-opinion-tolerable-upper-intake-level-iron
- [G6] Portuguese DGS/PNPAS food guidance. https://alimentacaosaudavel.dgs.pt/roda-dos-alimentos
  https://alimentacaosaudavel.dgs.pt/dieta-mediterranica
- [G7] NICE NG246, supported low-energy diet scope.
  https://www.nice.org.uk/guidance/ng246/chapter/Physical-activity-and-diet
- [R1] Morton et al. (2018), resistance-training protein meta-analysis; not a BMI-
  based deficit prescription. https://pubmed.ncbi.nlm.nih.gov/28698222
- [R2] Hall & Chow (2011), energy-intake-change estimation and uncertainty.
  https://pmc.ncbi.nlm.nih.gov/articles/PMC3127505

Before automatic recommendations reach ordinary users: approve intended population,
equation applicability, target offsets/screens, performance presets, clinical
routing, reference editions/forms, support-mode UX, rule windows, and escalation
copy with qualified review. Before adaptive proposals: additionally approve one
fully specified algorithm and its evaluation. Before medical-allergy suitability
claims: separate specialist validation would be required; none are promised here.

## 14. Revision summary

Retired: P95 nutrient bounds; reported-zero-as-measured-zero; mandatory g-only
source records; incorrect EU fibre definition; invented iron UL; NICE 800–1,600
attribution; BMI-based protein proxies; individual ±10% confidence claims; selected-
day/full-period TEE arithmetic; fixed-baseline clamp as claimed calibration;
uncapped upward prescriptions; heuristic day completeness; automatic constraint
relaxation; heuristic failure as infeasibility; recipe-as-infinite-batch inventory.

Retained: core deterministic planning/coaching, optional ChatGPT interaction,
source-aware arithmetic, snapshots, practical user-controlled targets, transparent
findings, no exercise double-counting, supportive rewards, and staged validation.
