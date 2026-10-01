# ClearShift Genie Benchmark Questions

**Space ID:** `01f1b7c3ebf81ee1af2c32ad528fca34`  
**Space Name:** ClearShift  
**Purpose:** Validate the natural-language-to-SQL layer of the Genie agent for certification-gated work clearance and OSHA readiness.  
**Question Set:** 15 benchmark questions with expected SQL answers  
**Generated:** 2026-09-30T21:45:44.948544

---

## Benchmark Questions and Expected SQL

### 1. Show all workers whose clearance is expiring soon along with the days remaining.

**Question ID:** `01f1bae5eb2d1ff6b01ff8dbec147fed`

**Expected SQL:**

```sql
SELECT employee_name, location, work_center_desc, qualification_name, days_until_expiry FROM horizontal_dev_serverless_catalog.clearshift.gold_shift_clearance WHERE clearance = 'CLEARED_EXPIRING' ORDER BY days_until_expiry ASC
```

### 2. How many first-time hazardous assignments are there at each plant?

**Question ID:** `01f1bae5eb141579a09abaed8b46dc14`

**Expected SQL:**

```sql
SELECT location, count(*) AS first_time_count FROM horizontal_dev_serverless_catalog.clearshift.gold_first_time_hazardous GROUP BY location ORDER BY first_time_count DESC
```

### 3. Which regulated certifications are expiring soonest?

**Question ID:** `01f1bae5eafe16b4a8ed7739a0680ca8`

**Expected SQL:**

```sql
SELECT employee_name, location, qualification_name, expires_on, days_until_expiry FROM horizontal_dev_serverless_catalog.clearshift.gold_renewal_pipeline WHERE is_regulated = true ORDER BY days_until_expiry ASC
```

### 4. Who at Grand Rapids is not cleared, and for which qualifications?

**Question ID:** `01f1bae5eae81e74a06b7cbce346b5ec`

**Expected SQL:**

```sql
SELECT employee_name, qualification_name, reason FROM horizontal_dev_serverless_catalog.clearshift.gold_shift_clearance WHERE clearance = 'NOT_CLEARED' AND location ILIKE '%Grand Rapids%'
```

### 5. Which plant has the most blocked workers?

**Question ID:** `01f1bae5ead21af8b4d751ceac699bfc`

**Expected SQL:**

```sql
WITH ranked_plants AS (SELECT location, blocked_workers, RANK() OVER (ORDER BY blocked_workers DESC) AS rnk FROM horizontal_dev_serverless_catalog.clearshift.gold_site_coverage WHERE location IS NOT NULL AND blocked_workers IS NOT NULL) SELECT location, blocked_workers FROM ranked_plants WHERE rnk = 1
```

### 6. List all workers with out-of-scope qualifications and where they are scoped.

**Question ID:** `01f1bae5eabd1dab9a4963273c4cc6de`

**Expected SQL:**

```sql
SELECT employee_id, qualification_name, state, scoped_to, employee_location FROM horizontal_dev_serverless_catalog.clearshift.gold_qualification_state WHERE state = 'OUT_OF_SCOPE'
```

### 7. Which workers require supervision for their scheduled shift?

**Question ID:** `01f1bae5eaaa13f4bb2a69de02a30212`

**Expected SQL:**

```sql
SELECT employee_name, location, work_center_desc, qualification_name, reason FROM horizontal_dev_serverless_catalog.clearshift.gold_shift_clearance WHERE clearance = 'SUPERVISION_REQUIRED'
```

### 8. Pull the audit trail for all NOT_CLEARED assignments at Peoria.

**Question ID:** `01f1bae5ea96132e8ff02bb20941c0cd`

**Expected SQL:**

```sql
SELECT as_of_date, employee_name, work_center_desc, qualification_name, clearance, reason, evidence_reference FROM horizontal_dev_serverless_catalog.clearshift.gold_audit_record WHERE clearance = 'NOT_CLEARED' AND location ILIKE '%Peoria%'
```

### 9. Which certifications have already lapsed?

**Question ID:** `01f1bae5ea831055b290f73cd7f0d26c`

**Expected SQL:**

```sql
SELECT employee_name, location, qualification_name, expires_on, days_until_expiry FROM horizontal_dev_serverless_catalog.clearshift.gold_renewal_pipeline WHERE bucket = 'LAPSED' ORDER BY days_until_expiry
```

### 10. Which certifications are due for renewal within 30 days?

**Question ID:** `01f1bae5ea6d1e51ba2c041af75a2fd8`

**Expected SQL:**

```sql
SELECT employee_name, location, qualification_name, expires_on, days_until_expiry FROM horizontal_dev_serverless_catalog.clearshift.gold_renewal_pipeline WHERE bucket = 'DUE_30' ORDER BY days_until_expiry
```

### 11. Who is scheduled to perform hazardous work for the first time?

**Question ID:** `01f1bae5ea5a1974be4b3da088841bbc`

**Expected SQL:**

```sql
SELECT employee_name, location, work_center_desc, qualification_name, regulation_reference, first_performance_status, clearance, reason FROM horizontal_dev_serverless_catalog.clearshift.gold_first_time_hazardous
```

### 12. Show confined space clearance across all plants.

**Question ID:** `01f1bae5ea461af39594bfc21e4516c4`

**Expected SQL:**

```sql
SELECT employee_name, location, clearance, reason FROM horizontal_dev_serverless_catalog.clearshift.gold_shift_clearance WHERE qualification_name ILIKE '%confined%' ORDER BY location
```

### 13. What is the coverage percentage at each plant?

**Question ID:** `01f1bae5ea3215e28b578c995a0866be`

**Expected SQL:**

```sql
SELECT location, coverage_pct FROM horizontal_dev_serverless_catalog.clearshift.gold_site_coverage WHERE location IS NOT NULL AND coverage_pct IS NOT NULL ORDER BY location
```

### 14. Which workers are not cleared for their scheduled shifts, and why?

**Question ID:** `01f1bae5ea1e156f8d0d2c7139237d3c`

**Expected SQL:**

```sql
SELECT employee_name, location, work_center_desc, qualification_name, reason FROM horizontal_dev_serverless_catalog.clearshift.gold_shift_clearance WHERE clearance = 'NOT_CLEARED'
```

### 15. How many scheduled assignments fall into each clearance verdict?

**Question ID:** `01f1bae5ea091991b4429cb6e9aa876c`

**Expected SQL:**

```sql
SELECT clearance, count(*) AS n FROM horizontal_dev_serverless_catalog.clearshift.gold_shift_clearance GROUP BY clearance ORDER BY n DESC
```

---

## Evaluation Criteria

Each benchmark question is evaluated for accuracy of:
- SQL generation from natural language
- Correct table and column references
- Proper filtering and aggregation logic
- Output ordering and formatting

The Genie agent is considered validated when all 15 benchmark questions generate SQL that matches the expected answers and produces identical results against the underlying data warehouse.

