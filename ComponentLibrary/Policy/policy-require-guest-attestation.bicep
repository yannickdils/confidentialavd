// ---------------------------------------------------------------------------
// Azure Policy Definition: Require Guest Attestation on Confidential AVD VMs
//
// Effect: AuditIfNotExists
// This audits (rather than denies) VMs that are missing or have a failed
// GuestAttestation extension. Use Deny if you want to block non-compliant
// deployments outright in a more mature environment.
//
// Scope this assignment to:
//   - The subscription or resource group containing your AVD session hosts
//   - NOT the image build subscription (those VMs are Trusted Launch, not CVM)
// ---------------------------------------------------------------------------

@description('Name for the policy definition.')
param policyDefinitionName string = 'require-guest-attestation-confidential-avd'

@description('Display name shown in the Azure Portal.')
param policyDisplayName string = 'Require Guest Attestation extension on Confidential AVD session hosts'

@description('Description shown in the Azure Portal.')
param policyDescription string = 'Ensures that all Confidential VM session hosts in Azure Virtual Desktop have the GuestAttestation extension installed and healthy. Without this extension, there is no cryptographic proof that the session host is running in a genuine AMD SEV-SNP Trusted Execution Environment.'

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Policy Definition
// ---------------------------------------------------------------------------
resource policyDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: policyDefinitionName
  properties: {
    displayName: policyDisplayName
    description: policyDescription
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: {
      category: 'Security Center'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        defaultValue: 'AuditIfNotExists'
        allowedValues: ['AuditIfNotExists', 'Disabled']
        metadata: {
          displayName: 'Effect'
          description: 'AuditIfNotExists audits non-compliant VMs. Use Disabled to turn off the policy.'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            // Target Azure VMs only
            field: 'type'
            equals: 'Microsoft.Compute/virtualMachines'
          }
          {
            // Only Confidential VMs (securityType = ConfidentialVM)
            field: 'Microsoft.Compute/virtualMachines/securityProfile.securityType'
            equals: 'ConfidentialVM'
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
        details: {
          type: 'Microsoft.Compute/virtualMachines/extensions'
          existenceCondition: {
            allOf: [
              {
                field: 'Microsoft.Compute/virtualMachines/extensions/publisher'
                equals: 'Microsoft.Azure.Security.WindowsAttestation'
              }
              {
                field: 'Microsoft.Compute/virtualMachines/extensions/type'
                equals: 'GuestAttestation'
              }
              {
                // Extension must have provisioned successfully
                field: 'Microsoft.Compute/virtualMachines/extensions/provisioningState'
                equals: 'Succeeded'
              }
            ]
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output policyDefinitionId   string = policyDef.id
output policyDefinitionName string = policyDef.name
