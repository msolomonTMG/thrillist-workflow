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

def handle_github_pull_request_review (push)
  action = push["action"]
  github_user = get_github_data push["sender"]["url"] #user who made gh change
  user = translate_github_user_to_jira_user github_user
  pull_request = push["pull_request"]
  jira_issues = get_jira_issues pull_request, "pull_request"

  if action == "submitted"
    review_state = push["review"]["state"]

    if review_state == "approved"
      code_reviewed_issues(jira_issues, pull_request, user)
    end

  elsif action == "review_requested"

  end

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
    #some branches have complementary prs in other repos, we should keep the QA labels in sync (not code review)
    if current_label == "needs qa" || current_label == "QAed"
      puts "gonna sync the github labels"
      sync_github_label_in_complementary_pr current_label, push
    end

  elsif action == "synchronize"
    #if the PR is labeled with needs qa and the PR is updated, kick the ticket to In QA
    if pull_request_labels.find {|x| x["name"] == "needs qa"} != nil
      #get latest commit message on pull request
      latest_commit_message = get_latest_commit_message pull_request, push["repository"]["commits_url"]
      #update jira ticket by moving to QA and commenting with the latest commit message
      update_message_jira jira_issues, pull_request, latest_commit_message, pull_request_labels, user
    end

  elsif action == "review_requested"
    requested_reviewer = get_github_data push["requested_reviewer"]["url"]
    jira_reviewer = translate_github_user_to_jira_user requested_reviewer
    clean_jira_reviewer = clean_jira_username jira_reviewer # remove the [~ ] from the name
    update_jira_reviewer jira_issues, user, clean_jira_reviewer

  elsif action == "opened"
    start_code_review jira_issues, pull_request, user

  elsif action == "closed"
    puts "#{user} just closed #{pull_request["title"]}"
    if pull_request["merged"] == true
      resolve_issues jira_issues, pull_request, user
    end
  end
end

def handle_comment (push)
  action = push["action"]
  #the user who made the action to the pull request
  github_user = get_github_data push["sender"]["url"]
  user = translate_github_user_to_jira_user github_user
  #the comment that was made
  comment = push["comment"]["body"]
  #pull request that this issue is associated with
  pull_request = get_github_data push["issue"]["pull_request"]["url"]
  #jira issues associated with the pull request
  jira_issues = get_jira_issues pull_request, "pull_request"
  #add the comment to jira issues
  comment_jira_issues jira_issues, comment, pull_request, user
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

def translate_jira_user_to_github_user (jira_user)
  case jira_user
  when "msolomon"
    return "msolomonTMG"
  when "kboateng"
    return "kwadwo"
  when "tsiegel"
    return "tarasiegel"
  when "mhaarhaus"
    return "samiamorwas"
  when "plange"
    return "pfunklange"
  when "ssicurelli"
    return "stefsic"
  when "lukemonaco"
    return "lmon"
  when "spenny"
    return "schuylerpenny"
  when "krichards"
    return "khalid-richards"
  when "jacinto"
    return "THRILL-jacinto"
  when "emchale"
    return "emchale"
  when "mpriscella"
    return "mpriscella"
  when "vtapia"
    return "vtapia5070"
  when "aduyko"
    return "aduyko"
  when "afeay"
    return "aidanfeay"
  when "blongstaff"
    return "benlongstaff"
  when "carriedennnis"
    return "cdennis"
  when "chaoli20"
    return "cli"
  when "emchale"
    return "emchale"
  when "kpeltzer"
    return "kpeltzer"
  when "smehta"
    return "ohiosonia"
  when "sleonard"
    return "scott-thrillist"
  when "jpage"
    return "jaepage"
  when "vrozman"
    return "vitaly-rozman"
  else
    return false
  end
end

def update_github_reviewer (pull_request_url, reviewer)
  url = pull_request_url + "/requested_reviewers?access_token=#{ENV['GITHUB_TOKEN']}"
  data = { "reviewers" => ["#{reviewer}"] }.to_json
  puts data
  puts url
  result = JSON.parse(RestClient.post(url, data, { :Accept => 'application/vnd.github.black-cat-preview+json' }))
  puts result
end

def sync_github_label_in_complementary_pr (label, push)
  puts "sync_github_label_in_complementary_pr"

  branch = push["pull_request"]["head"]["ref"]
  repo = push["repository"]["name"]
  org = push["repository"]["full_name"].split("/")[0]
  user = push["pull_request"]["user"]["login"]

  if repo == "Thrillist" || repo == "Seeker"
    # get the complementary Pinnacle PR
    complementary_pr = find_pull_request_by_branch branch, org, "Pinnacle"

  elsif repo == "Pinnacle"
    # try getting the complementary PR from each company repo -- only if the bot did not do the labeling
    #if action user is not github bot
    complementary_pr = find_pull_request_by_branch branch, org, "Thrillist"
    if complementary_pr == false
      complementary_pr = find_pull_request_by_branch branch, org, "Seeker"
    end
  end

  puts complementary_pr["title"]

  if complementary_pr != false
    complementary_pr_labels = get_labels complementary_pr
    #if the complementary pr already has the label, do nothing
    if complementary_pr_labels.find {|x| x["name"] == label} != nil
      return false
    else
      i = 0
      replacement_labels = [] #all current labels, replace "needs qa" with "QAed" and vice versa
      while (i < complementary_pr_labels.length) do
        this_label = complementary_pr_labels[i]["name"]
        skipThisLabel = (this_label == "QAed" && label == "needs qa") || (this_label == "needs qa" && label == "QAed")

        if this_label != label && !skipThisLabel
          replacement_labels.push(this_label)
        end
        i+=1
      end
      replacement_labels.push(label)

      #label_pull_request label, complementary_pr
      label_pull_request replacement_labels, complementary_pr
    end
  end
end

def label_pull_request (labels, pull_request)
  puts "label_pull_request"
  puts "labels are #{labels}"
  puts "pull request url is #{pull_request['_links']['issue']['href']}/labels"
  url = pull_request["_links"]["issue"]["href"] + "/labels"
  #data = "[\"#{label_name}\"]"
  # data = labels
  # puts data
  data = labels.to_s
  puts data
  response = JSON.parse(RestClient.put(url + "?access_token=#{ENV['GITHUB_TOKEN']}", data))
  puts response.to_json
end

def find_pull_request_by_branch (branch, org, repo)
  puts "find_pull_request_by_branch"
  puts "https://api.github.com/repos/#{org}/#{repo}/pulls?access_token=#{ENV['GITHUB_TOKEN']}"
  results = JSON.parse(RestClient.get("https://api.github.com/repos/#{org}/#{repo}/pulls?access_token=#{ENV['GITHUB_TOKEN']}"))
  i = 0;
  while (i < results.length) do
    result = results[i]
    if result["head"]["ref"] == branch
      return result
    end
    i+=1
  end
  return false
end

def find_pull_request_with_key (key)
  puts "finding Pr"
  url = "https://api.github.com/search/issues?q=user:thrillist+type:pr+is:open+#{key}&access_token=#{ENV['GITHUB_TOKEN']}"
  results = JSON.parse(RestClient.get(url))

  if results["total_count"] == 0
    #TODO: change this URL to be discovery
    url = "https://api.github.com/search/issues?q=user:groupninemedia+type:pr+is:open+#{key}&access_token=#{ENV['GITHUB_TOKEN']}"
    results = JSON.parse(RestClient.get(url))
    if results["total_count"] == 0
      return false
    else
      puts "getting PR with url: #{results["items"][0]["pull_request"]["url"]}"
      pr = JSON.parse(RestClient.get(results["items"][0]["pull_request"]["url"]))
      puts "got pr: #{pr}"
      return pr
    end
  else
    puts "getting PR with url: #{results["items"][0]["pull_request"]["url"]}"
    pr = JSON.parse(RestClient.get(results["items"][0]["pull_request"]["url"]))
    puts "got pr: #{pr}"
    return pr
  end

end
