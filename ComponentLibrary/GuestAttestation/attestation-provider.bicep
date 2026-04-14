@description('Name of the Attestation Provider resource.')
param attestationProviderName string

@description('Azure region for the Attestation Provider.')
param location string = resourceGroup().location

@description('Optional: base64-encoded policy signing certificate (PEM). Leave empty to use an unsigned policy.')
param policySigningCertificateData string = ''

@description('Tags to apply to all resources.')
param tags object

// ---------------------------------------------------------------------------
// Azure Attestation Provider
//
// The provider is the endpoint your Confidential VMs call to produce a signed
// attestation token. The token proves:
//   - The VM is running on genuine AMD SEV-SNP hardware
//   - Secure Boot and vTPM are enabled
//   - The TCB (Trusted Computing Base) has not been tampered with
//
// One provider is sufficient per region. If you already have a shared
// attestation provider in your tenant you can reference it instead of
// deploying a new one - just pass its URI as attestationProviderUri to the
// session host Bicep.
// ---------------------------------------------------------------------------
resource attestationProvider 'Microsoft.Attestation/attestationProviders@2021-06-01' = {
  name: attestationProviderName
  location: location
  tags: tags
  properties: {
    // publicNetworkAccess: Enabled is required for the GuestAttestation VM
    // extension to reach the endpoint. If you want private-only access you
    // need a private endpoint on the provider - see Microsoft docs.
    publicNetworkAccess: 'Enabled'
    // Optionally supply a policy signing certificate so only signed policies
    // can be applied to this provider.
    policySigningCertificates: empty(policySigningCertificateData)
      ? null
      : {
          keys: [
            {
              kty: 'RSA'
              x5c: [policySigningCertificateData]
            }
          ]
        }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output attestationProviderUri string = attestationProvider.properties.attestUri
output attestationProviderId  string = attestationProvider.id
output attestationProviderName string = attestationProvider.name
