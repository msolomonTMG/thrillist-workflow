require 'json'
require 'rest-client'
require './dev_variables' if File.exists?('./dev_variables.rb')

JIRA_HEADERS = {
  :"Authorization" => "Basic #{ENV['JIRA_TOKEN']}",
  :"Content-Type" => "application/json"
}

JIRA_URL = "https://thrillistmediagroup.atlassian.net/rest/api/latest/issue/"
JIRA_QA_IMAGE = "!https://webservices.tranware.net/TA/relay/success.png|height=48x,width=48px!"
JIRA_REVIEW_IMAGE = "!http://www.devart.com/images/products/logos/large/review-assistant.png|height=48px,width=48px!"


#Jira Transition IDs
START_PROGRESS_ID      = "181"
CODE_REVIEW_ID         = "171"
QA_READY_ID            = "191"
QA_PASSED_ID           = "271"
REVIEW_PASSED_ID       = "161"
DEPLOY_READY_ID        = "221"
PRODUCTION_VERIFIED_ID = "141"
CLOSED_ID              = "131"
RESOLVED_ID            = "231"

#Jira Custom Field IDs
REVIEWER_FIELD_ID      = "customfield_12401"

def handle_jira_issue_updated (push)
  changed_items = push["changelog"]["items"]
  i = 0
  while (i < changed_items.length) do
    item = changed_items[i]
    puts "i is #{i}"
    if item["field"] == "Reviewer"
      if item["to"] != ""
        github_reviewer = translate_jira_user_to_github_user item["to"]
        pull_request_url = find_pull_request_with_key push["issue"]["key"]

        if pull_request_url != false && github_reviewer != false
          update_github_reviewer pull_request_url, github_reviewer
        end
      end
    end
    i += 1
  end
end

#returns an array of jira issues associated with a pull request
#if there are more jira issues in the pull request title than in the branch, return the issues in the title
def get_jira_issues (code, type)
  if type == "branch"
    jira_issues = code.scan(/(?:|^)([A-Za-z]+-[0-9]+)(?=|$)/)
  elsif type == "pull_request"
    issues_in_branch = code["head"]["ref"].scan(/(?:|^)([A-Za-z]+-[0-9]+)(?=|$)/)
    issues_in_pull_request_title = code["title"].scan(/(?:\s|^)([A-Za-z]+-[0-9]+)(?=\s|$)/)
    # if there are more tickets in the branch than in the pull request, use the tickets in the branch, else use pr tickets
    if issues_in_branch.length > issues_in_pull_request_title.length
      jira_issues = issues_in_branch
    else
      jira_issues = issues_in_pull_request_title
    end
  end

  return jira_issues
end

#returns jira markdown for the user
#if this is a thrillist user, we assume their email is their jira name
#some user have special treatment because of the way they are setup
def translate_github_user_to_jira_user (github_user_object)
  #Example: msolomon@thrillist.com
  #user_email_domain = thrillist.com
  #user_email_prefix = msolomon
  if github_user_object["email"] != nil
    user_email_domain = github_user_object["email"].split('@')[1]
    user_email_prefix = github_user_object["email"].split('@')[0]

    #convert prefix to JIRA markdown or a link to github name if email domain is not thrillist
    if user_email_domain == "thrillist.com"
      user = user_email_prefix.insert(0, "[~") + "]"
    end
  else
    user = "["+github_user_object["login"]+"|"+github_user_object["html_url"]+"]"
  end

  #overwrite special cases
  case github_user_object["login"]
  when "kpeltzer"
    user = "[~kpeltzer]"
  when "ken"
    user = "[~kpeltzer]"
  when "kwadwo"
    user = "[~kboateng]"
  when "tarasiegel"
    user = "[~tsiegel]"
  when "samiamorwas"
    user = "[~mhaarhaus]"
  when "patrick"
    user = "[~plange]"
  when "pfunklange"
    user = "[~plange]"
  when "stefsic"
    user = "[~ssicurelli]"
  when "lmon"
    user = "[~lukemonaco]"
  when "schuylerpenny"
    user = "[~spenny]"
  when "khalid-richards"
    user = "[~krichards]"
  when "THRILL-jacinto"
    user = "[~jacinto]"
  when "emchale"
    user = "[~emchale]"
  when "mpriscella"
    user = "[~mpriscella]"
  when "vtapia5070"
    user = "[~vtapia]"
  end

  return user
end

def update_jira_reviewer (jira_issues, user, jira_reviewer)
  puts "updating reviewer"
  i = 0
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join
    update_jira_field jira_issue, REVIEWER_FIELD_ID, jira_reviewer, user

    i += 1
  end
end

def update_label_jira (jira_issues, current_label, pull_request_labels, user)
  i = 0
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join
    #if the user labeled the pull request with QAed and the pull request is already labeled with reviewed, move to deploy ready
    if current_label == "QAed" && jira_issue != nil
      #move to qaed by user
      transition_issue jira_issue, QA_PASSED_ID, user
      #if this ticket is also reviewed, move to deploy ready
      if pull_request_labels.find {|x| x["name"] == "reviewed"} != nil
        transition_issue jira_issue, DEPLOY_READY_ID, user
      end
    elsif current_label == "reviewed" && jira_issue != nil
      #move to reveiwed by user
      transition_issue jira_issue, QA_READY_ID, user
      #if this ticket is also QAed, move to deploy ready
      if pull_request_labels.find {|x| x["name"] == "QAed"} != nil
        transition_issue jira_issue, DEPLOY_READY_ID, user
      end
    elsif current_label == "needs review" && jira_issue != nil
      transition_issue jira_issue, CODE_REVIEW_ID, user, "labeled"
    elsif current_label == "needs qa" && jira_issue != nil
      if pull_request_labels.find {|x| x["name"] == "needs review"}
        #if someone labels this with need QA but it also needs review, do nothing
      else
        transition_issue jira_issue, QA_READY_ID, user, "labeled"
      end
    elsif current_label == "Production verified" && jira_issue != nil
      #move to production verified by user
      transition_issue jira_issue, PRODUCTION_VERIFIED_ID, user
    else
      #dont need to do anything for this label
    end
    i+=1
  end
end

def clean_jira_username (username)
  return username.gsub!('~','').gsub('[', '').gsub(']', '')
end

def update_message_jira (jira_issues, pull_request, latest_commit_message, pull_request_labels, user)
  #if someone entered a message in their pull request commit with #comment, it will
  #already show up in Jira so there is no need to post it with this app
  if latest_commit_message.scan(/(?:\s|^)([A-Za-z]+-[0-9]+).+(#comment)(?=\s|$)/).length > 0
    apply_comment = false
  else
    apply_comment = true
  end

  #loop through all of the tickets associated with the pull request
  #update with the comment of latest commit if necessary and then move to QA if there is a reviewed label on the PR
  i = 0;
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join
    if apply_comment == true && pull_request_labels.find {|x| x["name"] == "reviewed"} != nil
      transition_issue jira_issue, QA_READY_ID, user, pull_request, "updated", latest_commit_message
    end
    i+=1
  end

end

#loops through all of the issues given as a parameter and sends them to the transition function
def start_code_review (jira_issues, pull_request, user)
  i = 0;
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join
    transition_issue jira_issue, CODE_REVIEW_ID, user, pull_request, "opened"
    i+=1
  end
end

def start_progress (jira_issues, user, branch)
  i = 0;
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join
    transition_issue jira_issue, START_PROGRESS_ID, user, branch
    i+=1
  end
end

def resolve_issues(jira_issues, pull_request, user)
  puts "resolving issue"
  i = 0;
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join
    transition_issue jira_issue, RESOLVED_ID, user, pull_request
    i+=1
  end
end

def close_issues(jira_issues, pull_request, user)
  i = 0;
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join
    transition_issue jira_issue, CLOSED_ID, user, pull_request
    i+=1
  end
end

def code_reviewed_issues(jira_issues, pull_request, user)
  i = 0;
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join
    transition_issue jira_issue, REVIEW_PASSED_ID, user, pull_request
    i+=1
  end
end

def comment_jira_issues(jira_issues, comment, pull_request, user)
  i = 0;
  while (i < jira_issues.length) do
    jira_issue = jira_issues[i].join

    url = JIRA_URL + jira_issue + "/comment"
    body = "#{user} commented on #{pull_request["title"]} in GitHub: {quote}#{comment}{quote}"
    data = { "body" => body }.to_json

    response = RestClient.post( url, data, JIRA_HEADERS )
    i+=1
  end
end

def update_jira_field (jira_issue, field, value, user)
  url = JIRA_URL + jira_issue
  #TODO: This probably will not work for other fields
  data = {
    "fields" => {
      field => { "name" => "#{value}" }
    }
  }.to_json

  return RestClient.put( url, data, JIRA_HEADERS )
end

# Accepts 1 Jira issue at a time
# Transitions the issue to the transition ID "update_to"
# User is the person who made an action to trigger the transition
# code_info is an optional array about the code that triggered this event (branches/pull requests)
def transition_issue (jira_issue, update_to, user, *code_info)
  puts "Transitioning #{jira_issue}"
  # JackThreads front end does not want these transitions anymore
  if jira_issue =~ /(?:|^)(JQWE-[0-9]+|PQ-[0-9]+)(?=|$)/i
    return false
  else
    url = JIRA_URL + jira_issue + "/transitions"
  end

  case update_to
    when START_PROGRESS_ID
      body = "Progress started when #{user} created branch: {{#{code_info[0]}}} in GitHub"
    when CODE_REVIEW_ID
      if code_info[0] == "labeled"
        body = "#{user} labeled the pull request with \"needs review\""
      else
        body = "#{user} opened pull request: [#{code_info[0]["title"]}|#{code_info[0]["html_url"]}]. Ready for Code Review"
      end
    when QA_READY_ID
      if code_info[1] == "updated"
        body = "#{user} updated pull request: [#{code_info[0]["title"]}|#{code_info[0]["html_url"]}] with comment: \n bq. #{code_info[2]}"
      elsif code_info[0] == "labeled"
        body = "#{user} labeled pull request with \"needs qa\""
      else
        body = "Code review passed by #{user} #{JIRA_REVIEW_IMAGE}"
      end
    when QA_PASSED_ID
      body = "QA passed by #{user} #{JIRA_QA_IMAGE}"
    when REVIEW_PASSED_ID
      body = "Code review passed by #{user} #{JIRA_REVIEW_IMAGE}"
    when DEPLOY_READY_ID
      body = "Deploy ready"
    when RESOLVED_ID
      body = "Deployed when #{user} merged [#{code_info[0]["title"]}|#{code_info[0]["html_url"]}] in Github"
    when CLOSED_ID
      body = "Closed when #{user} closed [#{code_info[0]["title"]}|#{code_info[0]["html_url"]}] in Github"
  end

  data = {
    "update" => {
      "comment" => [
        {
          "add" => {
            "body" => body
          }
        }
      ]
    },
    "transition" => {
      "id" => "#{update_to}"
    }
  }.to_json

  #figure out if this issue is able to be transitioned to where we want it to go
  #if we can transition it, post to JIRA, if we can't then don't send anything
  available_transitions = JSON.parse( RestClient.get( url, JIRA_HEADERS ) )
  able_to_transition = is_able_to_transition update_to, available_transitions

  if able_to_transition == true
    response = RestClient.post( url, data, JIRA_HEADERS )
  else
    puts "cannot transition this ticket"
    # remove the transition property and just comment on the ticket
    data = { "body" => body }.to_json
    url = url.split("/transitions")[0] + "/comment"
    puts data
    puts url
    response = RestClient.post( url, data, JIRA_HEADERS )
  end
  puts response.to_json

end

#returns true if the ticket's available transitions includes the transition that we want to update to
def is_able_to_transition(update_to, available_transitions)
  able_to_transition = false

  i = 0
  while (i < available_transitions["transitions"].length ) do
    available_transition = available_transitions["transitions"][i]
    if available_transition["id"] == update_to
      able_to_transition = true
      i += available_transitions["transitions"].length
    end
    i += 1
  end

  return able_to_transition
end
