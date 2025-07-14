const core = require('@actions/core');
const github = require('@actions/github');
const { stringify } = require('csv-stringify/sync');
const arraySort = require('array-sort');
const token = core.getInput('token', { required: false });
const eventPayload = require(process.env.GITHUB_EVENT_PATH);
const org = core.getInput('org', { required: false }) || eventPayload.organization.login;
const { owner, repo } = github.context.repo;
const { GitHub } = require('@actions/github/lib/utils');
const { createAppAuth } = require('@octokit/auth-app');

const appId = core.getInput('appid', { required: false });
const privateKey = core.getInput('privatekey', { required: false });
const installationId = core.getInput('installationid', { required: false });

const rolePermission = core.getInput('permission', { required: false }) || 'ADMIN';
const committerName = core.getInput('committer-name', { required: false }) || 'github-actions';
const committerEmail = core.getInput('committer-email', { required: false }) || 'github-actions@github.com';
const jsonExport = core.getInput('json', { required: false }) || 'FALSE';
const affil = core.getInput('affil', { required: false }) || 'ALL';
//const days = core.getInput('days', { required: false }) || '90';

//const to = new Date();
//const from = new Date();
//from.setDate(to.getDate() - days);

let octokit = null;
let id = [];

// GitHub App authentication
if (appId && privateKey && installationId) {
  octokit = new GitHub({
    authStrategy: createAppAuth,
    auth: {
      appId: appId,
      privateKey: privateKey,
      installationId: installationId,
    },
  });
} else {
  octokit = github.getOctokit(token);
}

// Utility function to introduce a delay with jitter
function randomJitter(base, jitter = 0.5) {
  // jitter in ms: ±50% by default
  const variation = base * jitter * (Math.random() - 0.5) * 2;
  return base + variation;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Utility function to log rate limit information
function logRateLimit(headers, location) {
  if (headers) {
    core.info(`[${location}] Rate Limit Remaining: ${headers['x-ratelimit-remaining']}`);
    core.info(`[${location}] Rate Limit Reset Time: ${new Date(headers['x-ratelimit-reset'] * 1000).toISOString()}`);
  } else {
    core.info(`[${location}] Rate limit headers not available.`);
  }
}

// Retry function with exponential backoff
async function retryWithBackoff(fn, location, retries = 5, delay = 2000) {
  for (let i = 0; i < retries; i++) {
    try {
      return await fn();
    } catch (error) {
      if (error.response && error.response.headers) {
        logRateLimit(error.response.headers, location); // Log rate limit info
      }

      if (i === retries - 1 || !error.message.includes('secondary rate limit')) {
        core.error(`[${location}] Error: ${error.message}`);
        throw error;
      }

      core.warning(`[${location}] Secondary rate limit hit. Retrying in ${delay * Math.pow(2, i)}ms...`);
      await sleep(delay * Math.pow(2, i)); // Exponential backoff
    }
  }
}

// Orchestrator
(async () => {
  try {
    const collabsArray = [];
    const emailArray = [];
    const mergeArray = [];
    const memberArray = [];
    await orgID();
    await repoNames(collabsArray);
    await ssoCheck(emailArray);
    await membersWithRole(memberArray);
    await mergeArrays(collabsArray, emailArray, mergeArray, memberArray);
    await report(mergeArray);
    if (jsonExport === 'TRUE') {
      await json(mergeArray);
    }
  } catch (error) {
    core.setFailed(error.message);
  }
})();

// Find orgid for organization
async function orgID() {
  try {
    const query = /* GraphQL */ `
      query ($org: String!) {
        organization(login: $org) {
          id
        }
      }
    `;
    const dataJSON = await retryWithBackoff(async () => {
      const response = await octokit.graphql({ query, org });
      logRateLimit(response.headers, 'orgID'); // Log rate limit info
      return response;
    }, 'orgID');

    id = dataJSON.organization.id;
  } catch (error) {
    core.setFailed(error.message);
  }
}

// Query all organization repository names
async function repoNames(collabsArray) {
  try {
    let page = 1;
    let perPage = 20;
    let morePages = true;

    while (morePages) {
      const { data: repos } = await retryWithBackoff(
        async () => {
          const response = await octokit.rest.repos.listForOrg({
            org,
            type: 'all',
            per_page: perPage,
            page: page,
          });
          // Optionally, check headers for rate limit and sleep if needed
          const sleepMs = getRateLimitSleep(response.headers);
          if (sleepMs > 0) {
            core.info(`Sleeping for ${sleepMs / 1000}s due to rate limit.`);
            await sleep(sleepMs);
          }
          return response;
        },
        'repoNames'
      );

      if (repos.length === 0) {
        morePages = false;
        break;
      }

      for (const repo of repos) {
        core.info(`Processing repo: ${repo.name}`);
        await sleep(randomJitter(12000)); // 12s ±6s
        await collabRole({ name: repo.name, visibility: repo.visibility }, collabsArray);
      }

      page++;
      await sleep(randomJitter(10000)); // 10s ±5s jitter between pages
    }
  } catch (error) {
    core.setFailed(error.message);
  }
}

// Query all repository collaborators
async function collabRole(repo, collabsArray) {
  try {
    let endCursor = null;
    const query = /* GraphQL */ `
      query ($owner: String!, $orgRepo: String!, $affil: CollaboratorAffiliation, $cursorID: String) {
        organization(login: $owner) {
          repository(name: $orgRepo) {
            collaborators(affiliation: $affil, first: 20, after: $cursorID) { // Reduced page size to 20
              edges {
                node {
                  login
                  name
                  email
                  organizationVerifiedDomainEmails(login: $owner)
                }
                permission
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

    let hasNextPage = false;

    do {
      const dataJSON = await retryWithBackoff(async () => {
        const response = await octokit.graphql({
          query,
          owner: org,
          orgRepo: repo.name,
          affil: affil,
          cursorID: endCursor,
        });
        logRateLimit(response.headers, 'collabRole'); // Log rate limit info
        return response;
      }, 'collabRole');

      const roles = dataJSON.organization.repository.collaborators.edges.map((role) => role);

      hasNextPage = dataJSON.organization.repository.collaborators.pageInfo.hasNextPage;

      for (const role of roles) {
        if (hasNextPage) {
          endCursor = dataJSON.organization.repository.collaborators.pageInfo.endCursor;
        } else {
          endCursor = null;
        }

        const login = role.node.login;
        const name = role.node.name || '';
        const verifiedEmail = role.node.organizationVerifiedDomainEmails
          ? role.node.organizationVerifiedDomainEmails.join(', ')
          : '';
       // const createdAt = role.node.createdAt.slice(0, 10) || '';
      //  const updatedAt = role.node.updatedAt ? role.node.udatedAt.slice(0, 10) || '';
        const permission = role.permission;
        const orgRepo = repo.name;
        const visibility = repo.visibility;

        if (role.permission === rolePermission) {
          collabsArray.push({
            orgRepo,
            login,
            name,
            verifiedEmail,
            permission,
            visibility,
            org,
          });
        } else if (rolePermission === 'ALL') {
          collabsArray.push({
            orgRepo,
            login,
            name,
            verifiedEmail,
            permission,
            visibility,
            org,
          });
        }
      }

      // Introduce a delay of 2 seconds between requests
      await sleep(randomJitter(10000));
    } while (hasNextPage);
  } catch (error) {
    core.setFailed(error.message);
  }
}


// Check if the organization has SSO enabled
async function ssoCheck(emailArray) {
  try {
    const query = /* GraphQL */ `
      query ($org: String!) {
        organization(login: $org) {
          samlIdentityProvider {
            id
          }
        }
      }
    `

    const dataJSON = await retryWithBackoff(() =>
      octokit.graphql({
        query,
        org: org
      })
    )

    if (dataJSON.organization.samlIdentityProvider) {
      await ssoEmail(emailArray)
    }
  } catch (error) {
    core.setFailed(error.message)
  }
}

// Retrieve all members of a SSO-enabled organization
async function ssoEmail(emailArray) {
  try {
    let paginationMember = null

    const query = /* GraphQL */ `
      query ($org: String!, $cursorID: String) {
        organization(login: $org) {
          samlIdentityProvider {
            externalIdentities(first: 20, after: $cursorID) { // Reduced page size to 20
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
    `

    let hasNextPageMember = false

    do {
     const dataJSON = await retryWithBackoff(async () => {
        const response = await octokit.graphql({ query, org: org, cursorID: paginationMember });
        logRateLimit(response.headers, 'ssoEmail'); // Log rate limit info
        return response;
    }, 'ssoEmail');

      const emails = dataJSON.organization.samlIdentityProvider.externalIdentities.edges

      hasNextPageMember = dataJSON.organization.samlIdentityProvider.externalIdentities.pageInfo.hasNextPage

      for (const email of emails) {
        if (hasNextPageMember) {
          paginationMember = dataJSON.organization.samlIdentityProvider.externalIdentities.pageInfo.endCursor
        } else {
          paginationMember = null
        }

        if (!email.node.user) continue
        const login = email.node.user.login
        const ssoEmail = email.node.samlIdentity.nameId

        emailArray.push({ login, ssoEmail })
      }

      // Introduce a delay of 2 seconds between requests
      await sleep(5000)
    } while (hasNextPageMember)
  } catch (error) {
    core.setFailed(error.message)
  }
}

// Query all organization members
async function membersWithRole(memberArray) {
  try {
    let endCursor = null
    const query = /* GraphQL */ `
      query ($owner: String!, $cursorID: String) {
        organization(login: $owner) {
          membersWithRole(first: 20, after: $cursorID) { // Reduced page size to 20
            edges {
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

    do {
      const dataJSON = await retryWithBackoff(async () => {
        const response = await octokit.graphql({ query, owner: org, cursorID: endCursor });
        logRateLimit(response.headers, 'membersWithRole'); // Log rate limit info
        return response;
    }, 'membersWithRole');

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

      // Introduce a delay of 2 seconds between requests
      await sleep(5000)
    } while (hasNextPage)
  } catch (error) {
    core.setFailed(error.message)
  }
}

// Append SSO email and org members by login key
async function mergeArrays(collabsArray, emailArray, mergeArray, memberArray) {
  try {
    collabsArray.forEach((collab) => {
      const login = collab.login
      const name = collab.name
     // const publicEmail = collab.publicEmail
      const verifiedEmail = collab.verifiedEmail
      const permission = collab.permission
      const visibility = collab.visibility
      const org = collab.org
      const orgRepo = collab.orgRepo
      //const createdAt = collab.createdAt
      //const updatedAt = collab.updatedAt
      //const activeContrib = collab.activeContrib
      //const sumContrib = collab.sumContrib

      const ssoEmail = emailArray.find((email) => email.login === login)
      const ssoEmailValue = ssoEmail ? ssoEmail.ssoEmail : ''

      const member = memberArray.find((member) => member.login === login)
      const memberValue = member ? member.role : 'OUTSIDE COLLABORATOR'

      ssoCollab = { orgRepo, login, name, ssoEmailValue, verifiedEmail, permission, org, memberValue }

      mergeArray.push(ssoCollab)
    })
    console.log(JSON.stringify(emailArray))
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
      permission: 'Repo permission',
      memberValue: 'Organization role',
      // activeContrib: 'Active contributions',
      // sumContrib: 'Total contributions',
      //createdAt: 'User created',
      //updatedAt: 'User updated',
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
