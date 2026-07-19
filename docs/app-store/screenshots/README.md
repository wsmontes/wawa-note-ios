# App Store screenshots

Related JIRA: KAN-70

The `en-US` directory contains the upload-ready Wawa Note 1.0 screenshot set in product-page order.

| File | Surface | Size | Alpha |
|---|---|---:|---:|
| `01-capture.jpg` | Capture dashboard and primary actions | 1320 × 2868 | No |
| `02-inbox.jpg` | Searchable review inbox | 1320 × 2868 | No |
| `03-explore.jpg` | Simple project collections | 1320 × 2868 | No |
| `04-detail.jpg` | Source-note detail | 1320 × 2868 | No |
| `05-privacy.jpg` | Privacy and external-processing controls | 1320 × 2868 | No |

All visible content is fictional and was inserted by the debug-only `--screenshot-demo` launch path on a clean iPhone 16 Pro Max simulator. The source screenshots were captured with `simctl io` at Apple's accepted 6.9-inch portrait size and converted to high-quality, three-channel JPEG because App Store screenshots cannot contain alpha.

Regeneration routes:

```text
--screenshot-demo
--screenshot-demo --screenshot-inbox
--screenshot-demo --screenshot-explore
--screenshot-demo --screenshot-detail
--screenshot-demo --screenshot-privacy
```

These launch routes are compiled only in Debug builds and do not exist in the App Store binary.
