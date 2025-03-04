const core = require('@actions/core')
const github = require('@actions/github')
const { stringify } = require('csv-stringify/sync')
const arraySort = require('array-sort')
const token = core.getInput('token', { required: true })
const eventPayload = require(process.env.GITHUB_EVENT_PATH)
const org = core.getInput('org', { required: false }) || eventPayload.organization.login
const { owner, repo } = github.context.repo
const { GitHub } = require('@actions/github/lib/utils')
const { createAppAuth } = require('@octokit/auth-app')

const appId = core.getInput('appid', { required: false })
const privateKey = core.getInput('privatekey', { required: false })
const installationId = core.getInput('installationid', { required: false })

const rolePermission = core.getInput('permission', { required: false }) || 'ADMIN'
const committerName = core.getInput('committer-name', { required: false }) || 'github-actions'
const committerEmail = core.getInput('committer-email', { required: false }) || 'github-actions@github.com'
const jsonExport = core.getInput('json', { required: false }) || 'FALSE'
const affil = core.getInput('affil', { required: false }) || 'ALL'
//const days = core.getInput('days', { required: false }) || '90'

//const to = new Date()
//const from = new Date()
//from.setDate(to.getDate() - days)

const { Octokit } = require("@octokit/core");
const { throttling } = require("@octokit/plugin-throttling");

const ThrottledOctokitPlugin = require("@octokit/plugin-throttling").ThrottledOctokitPlugin;

const throttledOctokit = new ThrottledOctokitPlugin({
  auth: "GITHUBREPOPERMS",
  throttle: {
    onRateLimit: async (retryAfter, options) => {
      throttledOctokit.log.warn(
        `Request quota exhausted for request ${options.method} ${options.url}`
      );

      // Check if the remaining requests are less than 1000
      if (options.rate.limit - options.rate.used < 1000) {
        console.log(`Pausing requests. Retry after ${retryAfter} seconds`);
        await new Promise(resolve => setTimeout(resolve, 10 * 60 * 1000)); // Pause for 10 minutes
        return true;
      }
    },
    onAbuseLimit: (retryAfter, options) => {
      throttledOctokit.log.warn(
        `Abuse detected for request ${options.method} ${options.url}`
      );

      // Convert 10 minutes to milliseconds
      const waitTime = 10 * 60 * 1000;

      setTimeout(() => {
        // Code to retry the request or resume execution goes here
      }, waitTime);

      return true; // Indicates that the request should be retried
    }
  }
});
let octokit = null
let id = []

// GitHub App authentication
if (appId && privateKey && installationId) {
  octokit = new GitHub({
    authStrategy: createAppAuth,
    auth: {
      appId: appId,
      privateKey: privateKey,
      installationId: installationId
    }
  })
} else {
  octokit = github.getOctokit(token)
}

// Orchestrator
;(async () => {
  try {
    const collabsArray = []
    const emailArray = []
    const mergeArray = []
    const memberArray = []
    await orgID()
    await repoNames(collabsArray)
    await ssoCheck(emailArray)
    await membersWithRole(memberArray)
    await mergeArrays(collabsArray, emailArray, mergeArray, memberArray)
    await report(mergeArray)
    if (jsonExport === 'TRUE') {
      await json(mergeArray)
    }
  } catch (error) {
    core.setFailed(error.message)
  }
})()

// Find orgid for organization
async function orgID() {
  try {
    const query = /* GraphQL */ `
      query ($org: String!) {
        organization(login: $org) {
          id
        }
      }
    `
    dataJSON = await octokit.graphql({
      query,
      org
    })

    id = dataJSON.organization.id
  } catch (error) {
    core.setFailed(error.message)
  }
}
const { Octokit } = require("@octokit/core");
const { throttling } = require("@octokit/plugin-throttling");

const throttledOctokitInstance = Octokit.plugin(throttling);

let newThrottledOctokitInstance = new ThrottledOctokit({
  auth: "GITHUBREPOPERMS",
  throttle: {
    onRateLimit: async (retryAfter, options) => {
      throttledOctokitInstance.log.warn(
        `Request quota exhausted for request ${options.method} ${options.url}`
      );

      // Check if the remaining requests are less than 1000
      if (options.rate.limit - options.rate.used < 1000) {
        console.log(`Pausing requests. Retry after ${retryAfter} seconds`);
        await new Promise(resolve => setTimeout(resolve, 10 * 60 * 1000)); // Pause for 10 minutes
        return true;
      }
    },
    onAbuseLimit: (retryAfter, options) => {
      throttledOctokitInstance.log.warn(
        `Abuse detected for request ${options.method} ${options.url}`
      );

      // Convert 10 minutes to milliseconds
      const waitTime = 10 * 60 * 1000;

      setTimeout(() => {
        // Code to retry the request or resume execution goes here
      }, waitTime);

      return true; // Indicates that the request should be retried
    }
  }
});
// Query all organization repository names
async function repoNames(collabsArray) {
  try {
    let endCursor = null
    const query = /* GraphQL */ `
      query ($owner: String!, $cursorID: String) {
        organization(login: $owner) {
          repositories(first: 100, after: $cursorID) {
            nodes {
              name
              visibility
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    `

    let hasNextPage = false
    let dataJSON = null

    do {
      dataJSON = await octokit.graphql({
        query,
        owner: org,
        cursorID: endCursor
      })

      const repos = dataJSON.organization.repositories.nodes.map((repo) => repo)

      hasNextPage = dataJSON.organization.repositories.pageInfo.hasNextPage

      for (const repo of repos) {
        if (hasNextPage) {
          endCursor = dataJSON.organization.repositories.pageInfo.endCursor
        } else {
          endCursor = null
        }
        await collabRole(repo, collabsArray)
        console.log(repo.name)
      }
    } while (hasNextPage)
  } catch (error) {
    core.setFailed(error.message)
  }
}
const { Octokit } = require("@octokit/core");
const { throttling } = require("@octokit/plugin-throttling");

const ThrottledOctokitInstance = Octokit.plugin(throttling);

let newOctokitInstance = new ThrottledOctokit({
  auth: "GITHUBREPOPERMS",
  throttle: {
    onRateLimit: async (retryAfter, options) => {
      newOctokitInstance.log.warn(
        `Request quota exhausted for request ${options.method} ${options.url}`
      );

      // Check if the remaining requests are less than 1000
      if (options.rate.limit - options.rate.used < 1000) {
        console.log(`Pausing requests. Retry after ${retryAfter} seconds`);
        await new Promise(resolve => setTimeout(resolve, 10 * 60 * 1000)); // Pause for 10 minutes
        return true;
      }
    },
    onAbuseLimit: (retryAfter, options) => {
      newOctokitInstance.log.warn(
        `Abuse detected for request ${options.method} ${options.url}`
      );

      // Convert 10 minutes to milliseconds
      const waitTime = 10 * 60 * 1000;

      setTimeout(() => {
        // Code to retry the request or resume execution goes here
      }, waitTime);

      return true; // Indicates that the request should be retried
    }
  }
});
// Query all repository collaborators
const { Octokit } = require("@octokit/core");
const { throttling } = require("@octokit/plugin-throttling");

const ThrottledOctokitPlugin = Octokit.plugin(throttling);

const octokitInstance = new ThrottledOctokit({
  auth: "GITHUBREPOPERMS",
  throttle: {
    onRateLimit: async (retryAfter, options) => {
      octokitInstance.log.warn(
        `Request quota exhausted for request ${options.method} ${options.url}`
      );

      // Check if the remaining requests are less than 1000
      if (options.rate.limit - options.rate.used < 1000) {
        console.log(`Pausing requests. Retry after ${retryAfter} seconds`);
        await new Promise(resolve => setTimeout(resolve, 10 * 60 * 1000)); // Pause for 10 minutes
        return true;
      }
    },
    onAbuseLimit: (retryAfter, options) => {
      octokitInstance.log.warn(
        `Abuse detected for request ${options.method} ${options.url}`
      );

      // Convert 10 minutes to milliseconds
      const waitTime = 10 * 60 * 1000;

      setTimeout(() => {
        // Code to retry the request or resume execution goes here
      }, waitTime);

      return true; // Indicates that the request should be retried
    }
  }
});
// Check if the organization has SSO enabled
async function ssoCheck(emailArray) {
  try {
    const query = /* GraphQL */ `
      query ($org: String!) {
        organization(login: $org) {
          samlIdentityProvider {
            id
          }
          enterprise {
            samlIdentityProvider {
              id
            }
          }
        }
      }
    `

const { Octokit } = require("@octokit/core");
const { throttling } = require("@octokit/plugin-throttling");

try {
  const dataJSON = await octokit.graphql({
    query,
    org: org
  });

  const orgSamlProvider = dataJSON.organization.samlIdentityProvider;
  const enterpriseSamlProvider = dataJSON.organization.enterprise.samlIdentityProvider;

  if (orgSamlProvider || enterpriseSamlProvider) {
    await ssoEmail(emailArray);
  } else {
    // Handle the case where neither SAML identity provider is available
    console.error("No SAML identity provider is enabled for the organization.");
  }
} catch (error) {
  console.error("Request failed due to the following response errors:", error);
}

// Unused variables (commented out for now)
// const retryAfter;
// const id;
// const newThrottledOctokitInstance;
// const ThrottledOctokitInstance;
// const membersWithRole;
// const mergeArrays;
// const ssoCollab;
// const report;
// const json;

async function ssoEmail(emailArray) {
  try {
    let paginationMember = null;

    const query = /* GraphQL */ `
      query ($org: String!, $cursorID: String) {
        organization(login: $org) {
          samlIdentityProvider {
            externalIdentities(first: 100, after: $cursorID) {
              totalCount
              edges {
                node {
                  samlIdentity {
                    nameId
                  }
                  user {
                    login
                  }
                }
              }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
      }
    `;

    let hasNextPageMember = false;
    let dataJSON = null;

    do {
      dataJSON = await octokit.graphql({
        query,
        org: org,
        cursorID: paginationMember
      });

      const emails = dataJSON.organization.samlIdentityProvider.externalIdentities.edges;

      hasNextPageMember = dataJSON.organization.samlIdentityProvider.externalIdentities.pageInfo.hasNextPage;

      for (const email of emails) {
        if (hasNextPageMember) {
          paginationMember = dataJSON.organization.samlIdentityProvider.externalIdentities.pageInfo.endCursor;
        } else {
          paginationMember = null;
        }

        if (!email.node.user) continue;
        const login = email.node.user.login;
        const ssoEmail = email.node.samlIdentity.nameId;

        emailArray.push({ login, ssoEmail });
      }
    } while (hasNextPageMember);
  } catch (error) {
    core.setFailed(error.message);
  }
}
const { Octokit } = require("@octokit/core");
const { throttling } = require("@octokit/plugin-throttling");

ThrottledOctokitInstance = Octokit.plugin(throttling);

octokitInstance = new ThrottledOctokit({
  auth: "GITHUBREPOPERMS",
  throttle: {
    onRateLimit: async (retryAfter, options) => {
      octokitInstance.log.warn(
        `Request quota exhausted for request ${options.method} ${options.url}`
      );

      // Check if the remaining requests are less than 1000
      if (options.rate.limit - options.rate.used < 1000) {
        console.log(`Pausing requests. Retry after ${retryAfter} seconds`);
        await new Promise(resolve => setTimeout(resolve, 10 * 60 * 1000)); // Pause for 10 minutes
        return true;
      }
    },
    onAbuseLimit: (retryAfter, options) => {
      octokitInstance.log.warn(
        `Abuse detected for request ${options.method} ${options.url}`
      );

      // Convert 10 minutes to milliseconds
      const waitTime = 10 * 60 * 1000;

      setTimeout(() => {
        // Code to retry the request or resume execution goes here
      }, waitTime);

      return true; // Indicates that the request should be retried
    }
  }
});
// Query all organization members
async function membersWithRole(memberArray) {
  try {
    let endCursor = null
    const query = /* GraphQL */ `
      query ($owner: String!, $cursorID: String) {
        organization(login: $owner) {
          membersWithRole(first: 100, after: $cursorID) {
            edges {
              cursor
              node {
                login
              }
              role
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      }
    `

    let hasNextPage = false
    let dataJSON = null

    do {
      dataJSON = await octokit.graphql({
        query,
        owner: org,
        cursorID: endCursor
      })

      const members = dataJSON.organization.membersWithRole.edges

      hasNextPage = dataJSON.organization.membersWithRole.pageInfo.hasNextPage

      for (const member of members) {
        if (hasNextPage) {
          endCursor = dataJSON.organization.membersWithRole.pageInfo.endCursor
        } else {
          endCursor = null
        }
        memberArray.push({ login: member.node.login, role: member.role })
      }
    } while (hasNextPage)
  } catch (error) {
    core.setFailed(error.message)
  }
}
const { Octokit } = require("@octokit/core");
const { throttling } = require("@octokit/plugin-throttling");

// Remove the existing declaration of 'ThrottledOctokit'
delete ThrottledOctokit;

// Declare 'ThrottledOctokit' with the desired value
delete ThrottledOctokit;
const ThrottledOctokit = Octokit.plugin(throttling);

octokitInstance = new ThrottledOctokit({
  auth: "GITHUBREPOPERMS",
  throttle: {
    onRateLimit: async (retryAfter, options) => {
      octokitInstance.log.warn(
        `Request quota exhausted for request ${options.method} ${options.url}`
      );

      // Check if the remaining requests are less than 1000
      if (options.rate.limit - options.rate.used < 1000) {
        console.log(`Pausing requests. Retry after ${retryAfter} seconds`);
        await new Promise(resolve => setTimeout(resolve, 10 * 60 * 1000)); // Pause for 10 minutes
        return true;
      }
    },
    onAbuseLimit: (retryAfter, options) => {
      octokitInstance.log.warn(
        `Abuse detected for request ${options.method} ${options.url}`
      );

      // Convert 10 minutes to milliseconds
      const waitTime = 10 * 60 * 1000;

      setTimeout(() => {
        // Code to retry the request or resume execution goes here
      }, waitTime);

      return true; // Indicates that the request should be retried
    }
  }
});
// Append SSO email and org members by login key
async function mergeArrays(collabsArray, emailArray, mergeArray, memberArray) {
  try {
    collabsArray.forEach((collab) => {
      const login = collab.login
      const name = collab.name
      const publicEmail = collab.publicEmail
      const verifiedEmail = collab.verifiedEmail
      const permission = collab.permission
      const visibility = collab.visibility
      const org = collab.org
      const orgRepo = collab.orgRepo
      const createdAt = collab.createdAt
      const updatedAt = collab.updatedAt
      const activeContrib = collab.activeContrib
      const sumContrib = collab.sumContrib

      const ssoEmail = emailArray.find((email) => email.login === login)
      const ssoEmailValue = ssoEmail ? ssoEmail.ssoEmail : ''

      const member = memberArray.find((member) => member.login === login)
      const memberValue = member ? member.role : 'OUTSIDE COLLABORATOR'

      ssoCollab = { orgRepo, visibility, login, name, ssoEmailValue, publicEmail, verifiedEmail, permission, org, createdAt, updatedAt, activeContrib, sumContrib, memberValue }

      mergeArray.push(ssoCollab)
    })
  } catch (error) {
    core.setFailed(error.message)
  }
}

// Create and push CSV report for all organization collaborators
async function report(mergeArray) {
  try {
    const columns = {
      orgRepo: 'Repository',
      visibility: 'Repo Visibility',
      login: 'Username',
      name: 'Full name',
      ssoEmailValue: 'SSO email',
      verifiedEmail: 'Verified email',
      publicEmail: 'Public email',
      permission: 'Repo permission',
      memberValue: 'Organization role',
      activeContrib: 'Active contributions',
      sumContrib: 'Total contributions',
      createdAt: 'User created',
      updatedAt: 'User updated',
      org: 'Organization'
    }

    const sortArray = arraySort(mergeArray, 'orgRepo')

    const csv = stringify(sortArray, {
      header: true,
      columns: columns,
      cast: {
        boolean: function (value) {
          return value ? 'TRUE' : 'FALSE'
        }
      }
    })

    const reportPath = `reports/${org}-${affil}-${rolePermission}-report.csv`
    const opts = {
      owner,
      repo,
      path: reportPath,
      message: `${new Date().toISOString().slice(0, 10)} repo collaborator report`,
      content: Buffer.from(csv).toString('base64'),
      committer: {
        name: committerName,
        email: committerEmail
      }
    }

    try {
      const { data } = await octokit.rest.repos.getContent({
        owner,
        repo,
        path: reportPath
      })

      if (data && data.sha) {
        opts.sha = data.sha
      }
    } catch (err) {}

    await octokit.rest.repos.createOrUpdateFileContents(opts)
  } catch (error) {
    core.setFailed(error.message)
  }
}

// Create and push optional JSON report for all organization collaborators
async function json(mergeArray) {
  try {
    const json = arraySort(mergeArray, 'orgRepo')

    const reportPath = `reports/${org}-${affil}-${rolePermission}-report.json`
    const opts = {
      owner,
      repo,
      path: reportPath,
      message: `${new Date().toISOString().slice(0, 10)} repo collaborator report`,
      content: Buffer.from(JSON.stringify(json, null, 2)).toString('base64'),
      committer: {
        name: committerName,
        email: committerEmail
      }
    }

    try {
      const { data } = await octokit.rest.repos.getContent({
        owner,
        repo,
        path: reportPath
      })

      if (data && data.sha) {
        opts.sha = data.sha
      }
    } catch (err) {}

    await octokit.rest.repos.createOrUpdateFileContents(opts)
  } catch (error) {
    core.setFailed(error.message)
  }
}
