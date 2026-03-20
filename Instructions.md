# Blog ↔ Codebase Alignment Checklist

**Blog title:** Building Confidential AVD Images with Azure Image Builder  
**Repo:** `yannickdils/confidentialavd`

Use this checklist to verify that every technical claim in the blog is backed by actual code in the repository. Items marked 🔴 are **new requirements** introduced by the platform-managed keys addition. Items marked 🟡 are **existing code that needs verification**. Items marked 🟢 are **nice-to-have improvements**.

---

## 🔴 Priority 1: Platform-managed keys (NEW - Option A)

The blog now describes a `VMGuestStateOnly` path that requires NO DES and NO Managed HSM. This is likely the biggest gap between the blog and your current codebase.

- [ ] **Create a `sessionHost-cc-pmk.bicep` module** (or add a parameter to existing `sessionHost-cc.bicep`)  
  The blog shows this Bicep for the platform-managed key path:
  ```
  securityEncryptionType: 'VMGuestStateOnly'
  // No diskEncryptionSet reference
  ```
  Verify your session host module can deploy with `VMGuestStateOnly` and no DES reference at all.

- [ ] **Add a parameter/toggle to switch between PMK and CMK**  
  The blog describes two options. The Bicep should accept something like `param encryptionMode string = 'VMGuestStateOnly' // or 'DiskWithVMGuestState'` to control which path is taken.

- [ ] **Update `AVD-DeployAdditionalHosts` pipeline to support PMK**  
  The pipeline currently has a `confidentialCompute` toggle. It may need a second toggle or a combined parameter like:
  - `confidentialCompute: true` + `customerManagedKeys: false` → deploys with `VMGuestStateOnly` (no DES)
  - `confidentialCompute: true` + `customerManagedKeys: true` → deploys with `DiskWithVMGuestState` + DES
  
  Verify the pipeline skips DES provisioning entirely when PMK is selected.

- [ ] **Verify `encryptionAtHost: false` for PMK path too**  
  The blog states this conflicts with BOTH `DiskWithVMGuestState` AND `VMGuestStateOnly`. Confirm the PMK Bicep also sets this to `false`.

- [ ] **Test a deployment with `VMGuestStateOnly`**  
  Deploy at least one session host using the PMK path end-to-end to confirm it works before publishing the blog.

---

## 🟡 Priority 2: Verify existing CMK code matches blog claims

These are things the blog describes that should already exist in your codebase - but verify they match exactly.

### Image Definition
- [ ] `imageDefinition.bicep` has `SecurityType: 'TrustedLaunchAndConfidentialVmSupported'` (not just `ConfidentialVmSupported`)
- [ ] `hyperVGeneration: 'V2'` is set
- [ ] Location is configurable (blog says `belgiumcentral` but it should be a parameter)

### Image Builder Template
- [ ] `imageTemplate.bicep` uses `Standard_DC8as_v6` as the build VM size (or a parameter that defaults to it)
- [ ] Source image references `office-365 / win11-25h2-avd-m365` (or is parameterized)
- [ ] All 12 customization steps from the blog exist as conditionally-included blocks:
  - [ ] Timezone Redirection (always)
  - [ ] Disable Storage Sense (always)
  - [ ] FSLogix Profile Containers (always)
  - [ ] Language Packs (optional flag)
  - [ ] RDP Shortpath (optional flag)
  - [ ] .NET 9 Desktop Runtime (optional flag)
  - [ ] Remove Office Apps (optional flag)
  - [ ] Windows Optimization / VDOT (always)
  - [ ] Disable Auto-Updates (optional flag)
  - [ ] Appx Package Removal (always)
  - [ ] Windows Update (always)
  - [ ] SysPrep (always)
- [ ] Replication regions include `westeurope`, `belgiumcentral`, `northeurope` (or are parameterized)
- [ ] `storageAccountType` defaults to `Standard_ZRS`
- [ ] `excludeFromLatest` defaults to `true`

### Disk Encryption Set (CMK path)
- [ ] `diskEncryptionSet.bicep` sets `encryptionType: 'ConfidentialVmEncryptedWithCustomerKey'`
- [ ] Uses `UserAssigned` identity (not `SystemAssigned`)
- [ ] `rotationToLatestKeyVersionEnabled: false` is set
- [ ] `activeKey.keyUrl` references a Managed HSM key URL (not standard Key Vault)
- [ ] **Verify:** The DES is NOT referenced at the top-level managed disk - only inside `securityProfile`

### Session Host (CMK path)
- [ ] `sessionHost-cc.bicep` sets `securityType: 'ConfidentialVM'`
- [ ] `encryptionAtHost: false`
- [ ] `secureBootEnabled: true`
- [ ] `vTpmEnabled: true`
- [ ] Managed disk uses `securityEncryptionType: 'DiskWithVMGuestState'`
- [ ] Managed disk references the DES inside `securityProfile` (not at the top level)
- [ ] `storageAccountType: 'Premium_LRS'` on the OS disk

### VM Extensions
- [ ] Domain Join extension is deployed (Entra ID join or AD join)
- [ ] Intune MDM enrollment extension is deployed
- [ ] AVD Agent (DSC) extension is deployed
- [ ] Azure Monitor Agent extension is deployed
- [ ] Dependency Agent extension is deployed
- [ ] **Guest Attestation extension is deployed** (CVM-specific - verify this exists)
- [ ] Data Collection Rule association is configured
- [ ] Extension dependency chain is correct (Domain Join before AVD Agent)

---

## 🟡 Priority 3: Pipeline logic matches blog claims

### AVD-GalleryInfrastructure Pipeline
- [ ] Pipeline deploys UAMI for AIB
- [ ] Pipeline deploys Azure Compute Gallery
- [ ] Pipeline deploys all image definitions
- [ ] Pipeline file exists at `pipelines/AVD-GalleryInfrastructure.yml`

### AVD-ImageBuild Pipeline
- [ ] Supports Azure Image Builder method
- [ ] Supports VM Capture method
- [ ] Auto-increments image version number
- [ ] Monitors build with log tailing from staging storage account
- [ ] Verifies image version exists in all replication regions after build
- [ ] Pipeline file exists at `pipelines/AVD-ImageBuild.yml`

### AVD-DeployAdditionalHosts Pipeline
- [ ] Supports `add` mode
- [ ] Supports `replace` mode
- [ ] `confidentialCompute` toggle exists and works
- [ ] When CC is enabled, uses the CC Bicep template
- [ ] When CC + CMK is enabled, deploys/retrieves the DES
- [ ] 🔴 When CC + PMK is enabled, skips DES entirely (new requirement)
- [ ] Selects CC-capable VM size from JSON configuration
- [ ] **Zone failover logic:**
  - [ ] Attempts Zone 1 first
  - [ ] Detects `SkuNotAvailable` / `ZonalAllocationFailed` errors
  - [ ] Cleans up partial deployment on failure
  - [ ] Retries in Zone 2, then Zone 3
  - [ ] Deploys ALL VMs in a single zone (doesn't split across zones)
- [ ] **Replace workflow:**
  - [ ] Disables new logons on target hosts
  - [ ] Sends user warnings with configurable delay
  - [ ] Force-logoff remaining sessions
  - [ ] Shutdowns and deallocates old VMs
  - [ ] Downgrades old OS disks to Standard HDD
  - [ ] Deploys new hosts
  - [ ] Schedules old host cleanup
- [ ] Pipeline file exists at `pipelines/AVD-DeployAdditionalHosts.yml`

---

## 🟡 Priority 4: Resource naming & architecture alignment

The blog references specific naming conventions and resource groups. Verify these are parameterized or match.

- [ ] Images subscription is named `sub-avd-images-prd` (or parameterized)
- [ ] AVD subscription is named `sub-avd-prd` (or parameterized)
- [ ] Resource group naming follows `rg-avd-images-prd-image-weu-001` pattern
- [ ] Host pool resource groups follow `rg-avd-prd-hp-*-weu-001` pattern
- [ ] Session host resource groups follow `rg-avd-prd-hp-*-hosts-weu-001` pattern
- [ ] Key Vault resource groups follow `rg-avd-prd-hp-*-kv-weu-001` pattern
- [ ] Image definition naming follows `imgd-avd-images-prd-cc-win11-25h2-001` pattern
- [ ] Cross-subscription image reference works (SPN with Reader on gallery subscription)

---

## 🟡 Priority 5: RBAC & identity alignment

- [ ] UAMI for AIB has correct permissions on gallery and image definition
- [ ] UAMI for DES has `Crypto Service Encryption User` role on the Managed HSM key
- [ ] SPN for AVD deployment has `Reader` access to the gallery subscription
- [ ] 🔴 When using PMK, no HSM RBAC is needed - verify the pipeline doesn't attempt HSM role assignments

---

## 🟢 Priority 6: GitHub repo structure matches blog links

The blog links to specific file paths. Verify these files exist at the expected locations.

- [ ] `bicep/modules/computeGallery/imageDefinition.bicep`
- [ ] `bicep/modules/imageBuilder/imageTemplate.bicep`
- [ ] `bicep/modules/diskEncryptionSet/diskEncryptionSet.bicep`
- [ ] `bicep/modules/sessionHosts/sessionHost-cc.bicep`
- [ ] 🔴 `bicep/modules/sessionHosts/sessionHost-cc-pmk.bicep` (or PMK support in sessionHost-cc.bicep)
- [ ] `pipelines/AVD-GalleryInfrastructure.yml`
- [ ] `pipelines/AVD-ImageBuild.yml`
- [ ] `pipelines/AVD-DeployAdditionalHosts.yml`

---

## 🟢 Priority 7: Nice-to-have documentation

- [ ] Add a `README.md` to the repo that mirrors the blog structure
- [ ] Add a `CONTRIBUTING.md` if you want community contributions
- [ ] Add parameter documentation for the PMK vs CMK choice
- [ ] Add a sample `parameters.json` showing both PMK and CMK configurations
- [ ] Add the architecture diagram PNG to the repo's `docs/` folder for reference

---

## Summary: What's likely missing

Based on the blog content, the **biggest gaps** are probably:

1. **PMK support** - if your codebase was built for CMK only, you need to add the `VMGuestStateOnly` path to the session host Bicep and the deploy pipeline
2. **Guest Attestation extension** - this is CVM-specific and might not be in your existing extension stack
3. **Pipeline PMK toggle** - the deploy pipeline needs to know when to skip DES provisioning entirely
4. **File paths** - if the repo isn't public yet, ensure the folder structure matches the blog's GitHub links before publishing