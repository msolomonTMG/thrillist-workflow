require 'sinatra'
require 'json'
require 'rest-client'
require './dev_variables' if File.exists?('./dev_variables.rb')
require './jira_helpers'
require './github_helpers'

get '/' do
  'Thrillist Workflow'
end

post '/payload' do
  #the type of event that happened in GitHub
  event = request.env["HTTP_X_GITHUB_EVENT"]
  #the JSON that GitHub webhook sends us
  push = JSON.parse(request.body.read)
  #if the event was a pull request, handle that differently than actions for branches
  if event == "pull_request"
    handle_github_pull_request push
  elsif event == "create" && push["ref_type"] == "branch"
    handle_github_branch push
  end
end
