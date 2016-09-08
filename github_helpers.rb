require 'json'
require 'rest-client'
require './dev_variables' if File.exists?('./dev_variables.rb')

def handle_github_branch (push)
  #the branch that was created
  branch = push["ref"]
  #the user who made the action to the pull request
  github_user = get_github_data push["sender"]["url"]
  user = translate_github_user_to_jira_user github_user
  #update the JIRA issue with the branch name
  jira_issues = get_jira_issues branch, "branch"
  #update_development_info_jira jira_issues, branch, "branch"
  start_progress jira_issues, user, branch
end

def handle_github_pull_request (push)
  #the action that was taken
  action = push["action"]
  #the user who made the action to the pull request
  github_user = get_github_data push["sender"]["url"]
  user = translate_github_user_to_jira_user github_user
  #the pull request that was actioned on
  pull_request = push["pull_request"]
  #array of labels applied to this pull request
  pull_request_labels = get_labels pull_request
  #jira issues associated with the pull request
  jira_issues = get_jira_issues pull_request, "pull_request"

  if action == "labeled"
    #the label that was just added to this pull request
    current_label = push["label"]["name"]
    #loop through all of the tickets and decide what to do based on the labels of this pull request
    update_label_jira jira_issues, current_label, pull_request_labels, user

  elsif action == "synchronize"
    #get latest commit message on pull request
    latest_commit_message = get_latest_commit_message pull_request, push["repository"]["commits_url"]
    #update jira ticket by moving to QA and commenting with the latest commit message if it's been reviewed
    update_message_jira jira_issues, pull_request, latest_commit_message, pull_request_labels, user

  elsif action == "opened"
    start_code_review jira_issues, pull_request, user

  elsif action == "closed"
    #if the pull request was merged, resolve the jira ticket
    if pull_request["merged_at"] != nil
      resolve_issues jira_issues, pull_request, user
    #if the pull request was closed, close the jira ticket
    else
      close_issues jira_issues, pull_request, user
    end
  end
end

def get_github_data (url)
  data = JSON.parse( RestClient.get( url, {:params => {:access_token => ENV['GITHUB_TOKEN']}, :accept => :json} ) )

  return data
end

#returns an array of labels applied to a pull request
def get_labels (pull_request)
  labels_url = pull_request["issue_url"] + "/labels"
  labels = get_github_data labels_url

  return labels
end

#returns message of the latest commit for a pull request
def get_latest_commit_message (pull_request, commits_url)
  commit_info_url = commits_url.split('{')[0] + '/' + pull_request["head"]["sha"]
  latest_commit_info = get_github_data commit_info_url
  latest_commit_message = latest_commit_info["commit"]["message"]

  return latest_commit_message
end
