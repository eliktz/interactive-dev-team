/**
 * @process agent-tooling-setup
 * @description Add Playwright MCP, Bitbucket MCP, and remove Figma refs from all agents
 * @inputs { projectDir: string }
 * @outputs { success: boolean, filesModified: array, servicesAdded: array }
 */

import { defineTask } from '@a5c-ai/babysitter-sdk';

/**
 * Agent Tooling Setup Process
 *
 * Phase 1: Add Playwright MCP service to docker-compose + configure for agents
 * Phase 2: Add Bitbucket Cloud MCP configuration
 * Phase 3: Remove Figma references from all agent CLAUDE.md/AGENTS.md files
 * Phase 4: Breakpoint for user review
 * Phase 5: Verify all changes are correct
 *
 * @param {Object} inputs
 * @param {string} inputs.projectDir
 * @param {Object} ctx
 */
export async function process(inputs, ctx) {
  const { projectDir = '.' } = inputs || {};

  // ============================================================================
  // PHASE 1: Add Playwright MCP browser service
  // ============================================================================

  ctx.log('Phase 1: Adding Playwright MCP browser service...');

  const playwrightResult = await ctx.task(addPlaywrightMcp, { projectDir });

  // ============================================================================
  // PHASE 2: Add Bitbucket Cloud MCP configuration
  // ============================================================================

  ctx.log('Phase 2: Adding Bitbucket Cloud MCP...');

  const bitbucketResult = await ctx.task(addBitbucketMcp, { projectDir });

  // ============================================================================
  // PHASE 3: Remove Figma references from all agent files
  // ============================================================================

  ctx.log('Phase 3: Removing Figma references...');

  const figmaResult = await ctx.task(removeFigmaRefs, { projectDir });

  // ============================================================================
  // PHASE 4: Breakpoint for review
  // ============================================================================

  await ctx.breakpoint({
    question: 'All changes applied:\n' +
      `- Playwright MCP: ${playwrightResult.summary}\n` +
      `- Bitbucket MCP: ${bitbucketResult.summary}\n` +
      `- Figma removal: ${figmaResult.filesModified.length} files updated\n\n` +
      'Review and approve to proceed with verification.',
    title: 'Agent Tooling — Review Changes',
    context: { runId: ctx.runId }
  });

  // ============================================================================
  // PHASE 5: Verify
  // ============================================================================

  ctx.log('Phase 5: Verifying all changes...');

  const verifyResult = await ctx.task(verifyChanges, {
    projectDir,
    playwrightResult,
    bitbucketResult,
    figmaResult
  });

  return {
    success: verifyResult.verified,
    filesModified: [
      ...playwrightResult.filesModified,
      ...bitbucketResult.filesModified,
      ...figmaResult.filesModified
    ],
    servicesAdded: ['playwright-mcp', 'bitbucket-mcp'],
    issues: verifyResult.issues
  };
}

// ============================================================================
// TASK DEFINITIONS
// ============================================================================

export const addPlaywrightMcp = defineTask('add-playwright-mcp', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Add Playwright MCP browser service',
  description: 'Add @playwright/mcp as a Docker service and configure agents to use it',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Senior DevOps Engineer',
      task: 'Add Playwright MCP as a browser automation service for the war room agents. Both war-room agents (Telegram-facing) and Paperclip agents need browser access to view the Go-North Next.js app.',
      context: { projectDir: args.projectDir },
      instructions: [
        'Read docker-compose.yml to understand the current service topology',
        'Add a new "playwright" service using the official Microsoft Docker image: mcr.microsoft.com/playwright/mcp',
        'Configure it to run headless Chromium on port 8931 with --no-sandbox',
        'The entrypoint should be: node cli.js --headless --browser chromium --no-sandbox --port 8931 --host 0.0.0.0',
        'Add it to the same Docker network so war-room and paperclip can reach it',
        'Create or update MCP configuration for the war-room container:',
        '  - Create a file at config/mcp-settings.json with the Playwright MCP server pointing to http://playwright:8931/mcp',
        '  - Update Dockerfile to COPY this config into the container at /home/claude/.claude/settings.local.json or add it via launch.sh',
        '  - The MCP config format for Claude Code URL-based servers is: {"mcpServers": {"playwright": {"url": "http://playwright:8931/mcp"}}}',
        'For Paperclip agents: they run inside the Paperclip container which also needs MCP config',
        '  - Add the same MCP URL config for the Paperclip service',
        'Make the playwright service a dependency of war-room (depends_on with service_started condition)',
        'Return summary of changes and list of modified files'
      ],
      outputFormat: 'JSON with summary (string), filesModified (array), dockerComposeChanges (string)'
    },
    outputSchema: {
      type: 'object',
      required: ['summary', 'filesModified'],
      properties: {
        summary: { type: 'string' },
        filesModified: { type: 'array', items: { type: 'string' } },
        dockerComposeChanges: { type: 'string' }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['devops', 'playwright', 'mcp']
}));

export const addBitbucketMcp = defineTask('add-bitbucket-mcp', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Add Bitbucket Cloud MCP configuration',
  description: 'Configure bitbucket-mcp for Bitbucket Cloud access',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Senior DevOps Engineer',
      task: 'Add Bitbucket Cloud MCP server configuration for war-room and Paperclip agents.',
      context: { projectDir: args.projectDir },
      instructions: [
        'The package is npm: bitbucket-mcp (MatanYemini) — supports Bitbucket Cloud',
        'Auth env vars: BITBUCKET_USERNAME, BITBUCKET_PASSWORD (app password), BITBUCKET_URL (default: https://api.bitbucket.org/2.0)',
        'For the war-room container:',
        '  - Add BITBUCKET_USERNAME and BITBUCKET_PASSWORD as env vars in docker-compose.yml (from .env)',
        '  - Add the MCP server to the MCP config file (the one created in the Playwright step)',
        '  - The MCP config entry: {"bitbucket": {"command": "npx", "args": ["-y", "bitbucket-mcp@latest"], "env": {"BITBUCKET_URL": "...", "BITBUCKET_USERNAME": "...", "BITBUCKET_PASSWORD": "..."}}}',
        'For the Paperclip container:',
        '  - Same MCP config but Paperclip agents need the bitbucket tools for PR management',
        'Add BITBUCKET_USERNAME and BITBUCKET_PASSWORD to .env.example with placeholder values',
        'Update the relevant agent CLAUDE.md files to mention Bitbucket as an available tool',
        'Return summary of changes'
      ],
      outputFormat: 'JSON with summary (string), filesModified (array)'
    },
    outputSchema: {
      type: 'object',
      required: ['summary', 'filesModified'],
      properties: {
        summary: { type: 'string' },
        filesModified: { type: 'array', items: { type: 'string' } }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['devops', 'bitbucket', 'mcp']
}));

export const removeFigmaRefs = defineTask('remove-figma-refs', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Remove Figma references from all agent files',
  description: 'Remove Figma MCP references and update agent roles to not depend on Figma',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'Technical Writer — Agent Configuration Specialist',
      task: 'Remove all Figma references from agent CLAUDE.md and AGENTS.md files. Replace Figma-specific instructions with browser-based visual review using the Playwright MCP (which is now available).',
      context: { projectDir: args.projectDir },
      instructions: [
        'Files to modify (all have Figma references):',
        '  - agents/captain/CLAUDE.md (1 ref in routing table)',
        '  - agents/ceo-gonorth/CLAUDE.md (3 refs)',
        '  - agents/ux-gonorth/CLAUDE.md (8 refs — major rewrite of "Figma Workflow" section)',
        '  - companies/go-north/agents/frontend-dev/AGENTS.md (1 ref)',
        '  - companies/go-north/agents/ux-designer/AGENTS.md (5 refs)',
        'Read each file first before editing',
        'For captain: change "Figma" to "design, visual, layout" in routing table',
        'For ceo-gonorth: replace Figma references with "visual review via browser"',
        'For ux-gonorth: rewrite the "Figma Workflow" section to use browser-based screenshots and visual review instead. Hedva should use Playwright to screenshot the app and annotate issues in markdown',
        'For frontend-dev: replace "Figma designs" with "design specs" or "approved designs"',
        'For ux-designer: replace Figma-specific tools with browser-based visual review. Remove "Figma source of truth" and replace with "design documentation in markdown"',
        'Do NOT remove the UX Designer role or capabilities — just replace the Figma tool dependency',
        'Return list of modified files'
      ],
      outputFormat: 'JSON with filesModified (array), changesSummary (string)'
    },
    outputSchema: {
      type: 'object',
      required: ['filesModified'],
      properties: {
        filesModified: { type: 'array', items: { type: 'string' } },
        changesSummary: { type: 'string' }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['cleanup', 'figma', 'agents']
}));

export const verifyChanges = defineTask('verify-changes', (args, taskCtx) => ({
  kind: 'agent',
  title: 'Verify all tooling changes',
  description: 'Review all modifications for correctness',

  agent: {
    name: 'general-purpose',
    prompt: {
      role: 'QA Engineer',
      task: 'Verify all agent tooling changes are correct and consistent.',
      context: {
        projectDir: args.projectDir,
        playwrightResult: args.playwrightResult,
        bitbucketResult: args.bitbucketResult,
        figmaResult: args.figmaResult
      },
      instructions: [
        'Read docker-compose.yml and verify:',
        '  - Playwright service exists with correct image and config',
        '  - Bitbucket env vars are present',
        '  - War-room depends on playwright service',
        'Read MCP config files and verify:',
        '  - Playwright MCP URL points to http://playwright:8931/mcp',
        '  - Bitbucket MCP has correct command and env vars',
        'Grep all agent files for remaining "Figma" or "figma" references',
        'Check Dockerfile for any needed changes (MCP config copy)',
        'Return verification results'
      ],
      outputFormat: 'JSON with verified (boolean), issues (array of strings)'
    },
    outputSchema: {
      type: 'object',
      required: ['verified'],
      properties: {
        verified: { type: 'boolean' },
        issues: { type: 'array', items: { type: 'string' } }
      }
    }
  },

  io: {
    inputJsonPath: `tasks/${taskCtx.effectId}/input.json`,
    outputJsonPath: `tasks/${taskCtx.effectId}/result.json`
  },

  labels: ['verification', 'qa']
}));
