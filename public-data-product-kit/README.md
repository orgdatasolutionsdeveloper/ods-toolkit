# Public Data Product Kit (Excel)

**Version 0.9.0 (beta). By John Stover, Org Data Solutions.**

One workbook that walks an association, nonprofit or research team through
publishing a **public data product**: one trusted dataset turned into
numbers your industry can cite. Nine sections, a readiness status for each,
and a publish gate that holds until the three sections the public depends on
are ready and the owner has signed off.

The same nine sections run online in the ODS Data Management Platform, where
each product gets a public page and a downloadable methodology. This is the
offline edition: open it, fill it in, print it.

---

## What is in the workbook

| Tab | What you record |
|---|---|
| **Start** | Your product (title, organization, responsible owner, version, status, sign-off), how to use the workbook, the readiness of all nine sections, and the publish gate. |
| **1. Purpose and audience** | What industry question the product answers, who it is for, and what belongs in each access tier. |
| **2. Governed measures** | Each metric with its definition, calculation, grain, owner, refresh frequency, limitations and version. One column per measure, up to eight. |
| **3. Sources and methodology** | Where each number comes from, how it was collected or integrated, when it last refreshed, and how to cite it. One column per source, up to six. |
| **4. Cohorts, comparisons and benchmarks** | Eligibility, peer groups, time-period consistency, minimum cell sizes, outliers and suppression. |
| **5. Privacy and access** | Public, member, staff or restricted; personally identifiable and commercially sensitive data; aggregation; who approves. |
| **6. Public experience** | Headline measures, the chart, plain-language interpretation, methodology download, embeds, accessibility. |
| **7. Narrative modules** | What changed, why it matters, who is affected, what the data does not establish, an example, what to do next. |
| **8. Contributor workflow** | How an industry participant proposes a change, how it is validated, reviewed, applied, recorded and acknowledged. |
| **9. Governed AI** | Which datasets and roles an assistant may use, citations, read-only authority, approval thresholds, logging, stopping rules. |

## How to use it

1. **Open `Public-Data-Product-Kit.xlsx`** in Excel 2016 or later, Excel for
   Microsoft 365, or LibreOffice Calc. Excel opens downloaded files in
   Protected View; the statuses already show, and **Enable Editing** lets
   you type.
2. **Name your product on the Start tab.** One product answers one industry
   question. Fill in the organization and the responsible owner: the person
   who signs off and answers "is this still right?"
3. **Work through the nine tabs in order.** Every tab has the same shape:
   the field, a hint, a worked example, a yellow cell for your answer, and a
   status. Required fields show **Required** until you answer them.
4. **Watch the readiness.** Each tab computes its own status (Not started,
   In progress, Ready) and the Start tab lists all nine. Sections 5 through
   8 also check a rule from the framework, for example that every measure
   has an audience tier or that the owner approved the narrative, and say
   what is still needed.
5. **Clear the publish gate.** Sections 2 (Governed measures), 3 (Sources
   and methodology) and 5 (Privacy and access) must be Ready, and the owner
   must enter a sign-off date. Until then the Start tab lists the blockers.
6. **Print.** Every tab is set up for landscape printing; the wide measure
   and source tabs repeat their label columns on each page.

## The worked example

The grey **Example** column on every tab is one finished product,
*Greenhouse Industry Pulse 2026*, answering "How is employment in greenhouse
production changing, and where?" from public Bureau of Labor Statistics
data. It shows the level of detail each field wants. The figures in it are
illustrative, not published statistics; replace everything with your own
product.

## Requirements and safety

- Excel 2016 or later, Excel for Microsoft 365, or LibreOffice Calc.
- **No macros, no add-ins, no external links.** The workbook uses plain
  formulas (`IF`, `COUNTIF`, `COUNTA`, `SUMPRODUCT`, `TRIM`, `SUBSTITUTE`,
  `LEFT`) and nothing else. Nothing leaves your machine; the only web
  addresses in it are printed as text on the Start tab.
- Dropdowns limit the fields that have a fixed set of answers (audience
  tier, yes/no, fold/suppress, confidence, product status). Everything else
  is free text.

## The online version

The hosted ODS Data Management Platform runs the same kit with measures
bound to live data, computed readiness, a generated methodology document, an
anonymous public page for each product and a review queue for proposals from
your industry. It is free for approved nonprofits and .org organizations on
public government data.

Ask for a walkthrough: **support@orgdatasolutions.com** ·
<https://data.orgdatasolutions.com>

**[Build this product online in a free workspace](https://data.orgdatasolutions.com/signup?src=toolkit-public-data-kit)**

## License

MIT License. Copyright (c) 2026 John Stover, Org Data Solutions. Provided
as-is, without warranty.
