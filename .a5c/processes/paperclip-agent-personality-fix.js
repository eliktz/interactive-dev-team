/**
 * @process paperclip-agent-personality-fix
 * @description Validate, diagnose, and fix Paperclip agent personality/instructions gap
 * @inputs { projectDir: string }
 * @outputs { success: boolean, findings: object, fixApplied: string, filesModified: array }
 */

import { defineTask } from '@a5c-ai/babysitter-sdk';

/**
 * Paperclip Agent Personality Fix Process
 *
 * Phases matching user request:
 *   1. VALIDATE — compare AGENTS.md files vs what setup.sh sends to Paperclip API
 *   2. IDENTIFY FLAWS — document what's wrong and why agents end up identical
 *   3. BREAKPOINT — present fix options to user for approval
 *   4. IMPLEMENT — make the fix reproducible for any new deployer
 *
 * @param {Object} inputs
 * @param {string} inputs.projectDir - Project root (default: '.')
 * @param {Object} ctx - Process context
 */
export async function process(inputs, ctx) {
  const { projectDir = '.' } = inputs;

  // ============================================================================
  // PHASE 1: VALIDATE — What do the AGENTS.md files contain vs what Paperclip gets?
  // ============================================================================

  ctx.log('Phase 1: Validating agent personality files vs Paperclip registration...');

  const validateResult = await ctx.task(validateAgentFiles, {
    projectDir
  });

  // ============================================================================
  // PHASE 2: IDENTIFY FLAWS — What went wrong in the setup process?
  // ============================================================================

  ctx.log('Phase 2: Identifying flaws in setup flow...');

  const flawsResult = await ctx.task(identifyFlaws, {
    projectDir,
    validationReport: validateResult
  });

  // ============================================================================
  // PHASE 3: BREAKPOINT — Present fix options for user approval
  // ============================================================================

  ctx.log('Phase 3: Presenting fix options...');

  const fixProposal = await ctx.task(proposeFix, {
    projectDir,
    validationReport: validateResult,
    flawsReport: flawsResult
  });

  await ctx.breakpoint({
    question: fixProposal.breakpointQuestion,
    title: 'Paperclip Agent Personality Fix — Approve Approach',
    context: {
      runId: ctx.runId,
      validationSummary: validateResult.summary,
      flawsSummary: flawsResult.summary,
      proposedFixes: fixProposal.options
    }
  });

  // ============================================================================
  // PHASE 4: IMPLEMENT — Apply the fix and make it reproducible
  // ============================================================================

  ctx.log('Phase 4: Implementing fix...');

  const implementResult = await ctx.task(implementFix, {
    projectDir,
    validationReport: validateResult,
    flawsReport: flawsResult,
    fixProposal
  });

  // ============================================================================
  // PHASE 5: VERIFY — Ensure the fix is correct and reproducible
  // ============================================================================

  ctx.log('Phase 5: Verifying fix...');

  const verifyResult = await ctx.task(verifyFix, {
    projectDir,
    implementResult
  });

  if (!verifyResult.verified) {
    await ctx.breakpoint({
      question: `Verification found issues:\n${verifyResult.issues.join('\n')}\n\nHow would you like to proceed?`,
      title: 'Fix Verification — Issues Found',
      context: {
        runId: ctx.runId,
        issues: verifyResult.issues
      }
    });
  }

  return {
    success: true,
    findings: {
      validation: validateResult,
      flaws: flawsResult
    },
    fixApplied: fixProposal.recommendedFix,
    filesModified: implementResult.filesModified || [],
    verified: verifyResult.verified
  };
}

// ============================================================================
// TASK DEFINITIONS
// ============================================================================

export const validateAgentFiles = defineTask('validate-agent-files', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Validate AGENTS.md files vs Paperclip registration',
  description: 'Compare what each AGENTS.md defines vs what setup.sh sends to Paperclip API',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'DevOps Investigator',
      task: 'Compare the AGENTS.md personality files in companies/go-north/agents/ with what scripts/setup.sh actually sends to the Paperclip API when registering agents. Document each agent\'s unique personality content from AGENTS.md, then show the exact API payload from setup.sh. Identify the gap.',
      context: {
        projectDir: args.projectDir,
        agentsDir: 'companies/go-north/agents/',
        setupScript: 'scripts/setup.sh',
        paperclipYaml: 'companies/go-north/.paperclip.yaml'
      },
      instructions: [
        'Read ALL 6 AGENTS.md files in companies/go-north/agents/*/',
        'Read scripts/setup.sh — find the AGENT_DEFS array and the curl POST calls',
        'Read companies/go-north/.paperclip.yaml for adapter config',
        'For each agent: document what AGENTS.md says (unique role, capabilities, behavior rules) vs what the API payload contains',
        'Check if Paperclip API supports an "instructions" or "systemPrompt" field',
        'Write findings to a validation-report.md file in the project root',
        'Return a structured summary as JSON'
      ],
      outputFormat: 'JSON with summary (string), agents (array of {slug, hasUniquePersonality, apiPayloadHasPersonality, gap}), reportPath (string)'
    },
    outputSchema: {
      type: 'object',
      required: ['summary', 'agents'],
      properties: {
        summary: { type: 'string' },
        agents: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              slug: { type: 'string' },
              hasUniquePersonality: { type: 'boolean' },
              apiPayloadHasPersonality: { type: 'boolean' },
              gap: { type: 'string' }
            }
          }
        },
        reportPath: { type: 'string' }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['investigation', 'validation']
}));

export const identifyFlaws = defineTask('identify-flaws', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Identify flaws in agent setup process',
  description: 'Analyze the complete pipeline from AGENTS.md to deployed Paperclip agent and identify all gaps',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Systems Architect — Agent Platform Specialist',
      task: 'Given the validation report, identify ALL flaws in the setup pipeline that cause agents to lose their unique personality when deployed to Paperclip.',
      context: {
        projectDir: args.projectDir,
        validationReport: args.validationReport
      },
      instructions: [
        'Review the validation report from the previous phase',
        'Trace the complete agent lifecycle: AGENTS.md file → setup.sh → Paperclip API → deployed agent',
        'Identify every point where personality/instructions are lost',
        'Check if .paperclip.yaml has a mechanism for passing instructions',
        'Check the Paperclip repo (if cloned in ./paperclip/) for how agents receive system prompts',
        'Check the COMPANY.md schema for any instruction-passing mechanism',
        'Document each flaw with root cause and impact',
        'Return structured findings'
      ],
      outputFormat: 'JSON with summary (string), flaws (array of {id, title, rootCause, impact, severity})'
    },
    outputSchema: {
      type: 'object',
      required: ['summary', 'flaws'],
      properties: {
        summary: { type: 'string' },
        flaws: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'string' },
              title: { type: 'string' },
              rootCause: { type: 'string' },
              impact: { type: 'string' },
              severity: { type: 'string' }
            }
          }
        }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['investigation', 'analysis']
}));

export const proposeFix = defineTask('propose-fix', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Propose fix options for agent personality gap',
  description: 'Design fix options that ensure each Paperclip agent receives its unique personality',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Solutions Architect',
      task: 'Propose 2-3 concrete fix options to ensure Paperclip agents receive their unique AGENTS.md personality during setup. Each option must be reproducible — a first-time deployer running setup.sh should get correctly configured agents without manual steps.',
      context: {
        projectDir: args.projectDir,
        validationReport: args.validationReport,
        flawsReport: args.flawsReport
      },
      instructions: [
        'Review the validation and flaws reports',
        'Propose 2-3 concrete options with trade-offs',
        'Option A: Modify setup.sh to read AGENTS.md and pass content as agent instructions via Paperclip API',
        'Option B: Use Paperclip company import if available (read .paperclip.yaml + AGENTS.md files)',
        'Option C: Any other approach discovered from the Paperclip codebase',
        'For each option: describe changes needed, files modified, pros/cons',
        'Recommend one option and explain why',
        'Formulate a clear breakpoint question with the options for user approval',
        'Return structured proposal'
      ],
      outputFormat: 'JSON with options (array of {id, title, description, filesModified, pros, cons}), recommendedFix (string), breakpointQuestion (string)'
    },
    outputSchema: {
      type: 'object',
      required: ['options', 'recommendedFix', 'breakpointQuestion'],
      properties: {
        options: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'string' },
              title: { type: 'string' },
              description: { type: 'string' },
              filesModified: { type: 'array', items: { type: 'string' } },
              pros: { type: 'array', items: { type: 'string' } },
              cons: { type: 'array', items: { type: 'string' } }
            }
          }
        },
        recommendedFix: { type: 'string' },
        breakpointQuestion: { type: 'string' }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['design', 'proposal']
}));

export const implementFix = defineTask('implement-fix', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Implement the approved fix',
  description: 'Apply the approved fix to setup.sh and related files so agent personalities are properly passed to Paperclip',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Senior DevOps Engineer',
      task: 'Implement the approved fix to ensure Paperclip agents receive their unique AGENTS.md personality during setup. The fix must be reproducible — whoever runs setup.sh for the first time should get correctly configured agents.',
      context: {
        projectDir: args.projectDir,
        validationReport: args.validationReport,
        flawsReport: args.flawsReport,
        fixProposal: args.fixProposal
      },
      instructions: [
        'Implement the recommended fix (or the user-approved alternative)',
        'Key changes likely needed in scripts/setup.sh:',
        '  - Read each AGENTS.md file content during agent registration',
        '  - Pass content as "instructions" or "systemPrompt" in the API payload',
        '  - Handle multiline markdown content in JSON payloads correctly',
        'If Paperclip API does not support instructions field, adapt the approach',
        'Test that the JSON payloads are well-formed',
        'Update companies/go-north/.paperclip.yaml if needed',
        'Make sure setup.sh remains idempotent (safe to run multiple times)',
        'Return list of modified files and summary of changes'
      ],
      outputFormat: 'JSON with filesModified (array), changesSummary (string), setupScriptChanges (string)'
    },
    outputSchema: {
      type: 'object',
      required: ['filesModified', 'changesSummary'],
      properties: {
        filesModified: { type: 'array', items: { type: 'string' } },
        changesSummary: { type: 'string' },
        setupScriptChanges: { type: 'string' }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['implementation', 'fix']
}));

export const verifyFix = defineTask('verify-fix', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Verify the fix is correct and reproducible',
  description: 'Review the implemented changes to ensure they correctly pass unique personalities to each agent',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'QA Engineer — DevOps Specialist',
      task: 'Verify that the implemented fix correctly passes unique AGENTS.md content to each Paperclip agent during setup. Ensure it is reproducible for a first-time deployer.',
      context: {
        projectDir: args.projectDir,
        implementResult: args.implementResult
      },
      instructions: [
        'Read the modified setup.sh and verify:',
        '  1. Each agent registration includes unique personality content from AGENTS.md',
        '  2. JSON payloads are well-formed (no quoting issues with markdown content)',
        '  3. The script remains idempotent',
        '  4. Error handling is present (what if AGENTS.md is missing?)',
        '  5. The fix works for both fresh installs and re-runs',
        'Check that .paperclip.yaml and AGENTS.md files are consistent',
        'Verify the documentation mentions this personality setup',
        'Return verification results'
      ],
      outputFormat: 'JSON with verified (boolean), issues (array of strings), recommendations (array of strings)'
    },
    outputSchema: {
      type: 'object',
      required: ['verified'],
      properties: {
        verified: { type: 'boolean' },
        issues: { type: 'array', items: { type: 'string' } },
        recommendations: { type: 'array', items: { type: 'string' } }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['verification', 'qa']
}));
