// map branch to tag to use in operator.yaml and csv.yaml
def JOB_BRANCHES = ["2.10":"7.32.x", "2.x":"main"]
def JOB_DISABLED = ["2.10":true, "2.x":false]
for (JB in JOB_BRANCHES) {
    SOURCE_BRANCH=JB.value
    JOB_BRANCH=""+JB.key
    MIDSTM_BRANCH="crw-" + JOB_BRANCH.replaceAll(".x","") + "-rhel-8"
    jobPath="${FOLDER_PATH}/${ITEM_NAME}_" + JOB_BRANCH
    pipelineJob(jobPath){
        disabled(JOB_DISABLED[JB.key]) // on reload of job, disable to avoid churn
        UPSTM_NAME="chectl"
        SOURCE_REPO="che-incubator/" + UPSTM_NAME

        description('''
Artifact builder + sync job; triggers cli build after syncing from upstream

<ul>
<li>Upstream: <a href=https://github.com/''' + SOURCE_REPO + '''>''' + UPSTM_NAME + '''</a></li>
<li>Downstream: <a href=https://github.com/redhat-developer/codeready-workspaces-chectl/tree/''' + MIDSTM_BRANCH + '''>crwctl</a></li>
</ul>

Results:  <a href=https://github.com/redhat-developer/codeready-workspaces-chectl/releases>chectl/releases</a>
        ''')

        properties {
            ownership {
                primaryOwnerId("nboldt")
            }

            githubProjectUrl("https://github.com/" + SOURCE_REPO)

            pipelineTriggers {
                triggers{
                    pollSCM{
                        scmpoll_spec("H H/3 * * *") // every 3hrs
                    }
                }
            }

            disableResumeJobProperty()
        }

        throttleConcurrentBuilds {
            maxPerNode(1)
            maxTotal(1)
        }

        logRotator {
            daysToKeep(15)
            numToKeep(15)
            artifactDaysToKeep(7)
            artifactNumToKeep(5)
        }

        parameters{
            stringParam("SOURCE_BRANCH", SOURCE_BRANCH)
            stringParam("MIDSTM_BRANCH", MIDSTM_BRANCH)
            if (JOB_BRANCH.equals("2.9")) {
                stringParam("CSV_VERSION", "2.9.0", "Full version (x.y.z), used in CSV and crwctl version")
                stringParam("CSV_QUAY_TAG", "2.9", "Floating tag to use in operator.yaml and csv.yaml")
            }
            if (JOB_BRANCH.equals("2.10")) {
                stringParam("CSV_VERSION", "2.10.0", "Full version (x.y.z), used in CSV and crwctl version")
                stringParam("CSV_QUAY_TAG", "latest", "Floating tag to use in operator.yaml and csv.yaml")
            }
            MMdd = ""+(new java.text.SimpleDateFormat("MM-dd")).format(new Date())
            stringParam("versionSuffix", "", '''
if set, use as version suffix before commitSHA: RC-''' + MMdd + ''' --> ''' + JOB_BRANCH + '''.0-RC-''' + MMdd + '''-commitSHA;<br/>
if unset, version is CRW_VERSION-YYYYmmdd-commitSHA<br/>
:: if suffix = GA, use server and operator tags from RHEC stage<br/>
:: if suffix contains RC, use server and operator tags from Quay<br/>
:: for all other suffixes, use server and operator tags = ''' + JOB_BRANCH + '''<br/>
:: NOTE: yarn will fail for version = x.y.z.a but works with x.y.z-a''')
            booleanParam("PUBLISH_ARTIFACTS_TO_GITHUB", false, "default false; check box to publish to GH releases")
            booleanParam("PUBLISH_ARTIFACTS_TO_RCM", false, "default false; check box to upload sources + binaries to RCM for a GA release ONLY")
        }

        // Trigger builds remotely (e.g., from scripts), using Authentication Token = CI_BUILD
        authenticationToken('CI_BUILD')

        definition {
            cps{
                sandbox(true)
                script(readFileFromWorkspace('jobs/CRW_CI/crwctl_'+JOB_BRANCH+'.jenkinsfile'))
            }
        }
    }
}