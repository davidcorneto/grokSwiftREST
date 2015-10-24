//
//  GitHubAPIManager.swift
//  grokSwiftREST
//
//  Created by Christina Moulton on 2015-09-11.
//  Copyright © 2015 Teak Mobile Inc. All rights reserved.
//

import Foundation
import Alamofire
import SwiftyJSON
import Locksmith

class GitHubAPIManager {
  static let sharedInstance = GitHubAPIManager()
  var alamofireManager:Alamofire.Manager
  
  static let ErrorDomain = "com.error.GitHubAPIManager"
  
  let clientID: String = "1234567890"
  let clientSecret: String = "abcdefghijkl"
  
  func clearCache() {
    let cache = NSURLCache.sharedURLCache()
    cache.removeAllCachedResponses()
  }
  
  // handlers for the OAuth process
  // stored as vars since sometimes it requires a round trip to safari which
  // makes it hard to just keep a reference to it
  var OAuthTokenCompletionHandler:(NSError? -> Void)?
  
  init () {
    let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
    alamofireManager = Alamofire.Manager(configuration: configuration)
  }
  
  var OAuthToken: String? {
    set {
      if let valueToSave = newValue {
        do {
          try Locksmith.updateData(["token": valueToSave], forUserAccount: "github")
        } catch {
          let _ = try? Locksmith.deleteDataForUserAccount("github")
        }
      }
      else { // they set it to nil, so delete it
        let _ = try? Locksmith.deleteDataForUserAccount("github")
      }
    }
    get {
      // try to load from keychain
      Locksmith.loadDataForUserAccount("github")
      let dictionary = Locksmith.loadDataForUserAccount("github")
      if let token =  dictionary?["token"] as? String {
        return token
      }
      return nil
    }
  }
  
  // MARK: - Basic Auth
  func printMyStarredGistsWithBasicAuth() -> Void {
    Alamofire.request(GistRouter.GetPublic())
      .responseString { response in
        if let receivedString = response.result.value {
          print(receivedString)
        }
    }
  }
  
  func doGetWithBasicAuth() -> Void {
    let username = "myUsername"
    let password = "myPassword"
    Alamofire.request(.GET, "https://httpbin.org/basic-auth/\(username)/\(password)")
      .authenticate(user: username, password: password)
      .responseString { response in
        if let receivedString = response.result.value {
          print(receivedString)
        }
    }
  }
  
  // MARK: - OAuth 2.0
  func hasOAuthToken() -> Bool {
    if let token = self.OAuthToken {
      return !token.isEmpty
    }
    return false
  }
  
  // MARK: - OAuth flow
  func URLToStartOAuth2Login() -> NSURL? {
    let defaults = NSUserDefaults.standardUserDefaults()
    defaults.setBool(true, forKey: "loadingOAuthToken")
    
    let authPath:String = "https://github.com/login/oauth/authorize?client_id=\(clientID)&scope=gist&state=TEST_STATE"
    guard let authURL:NSURL = NSURL(string: authPath) else {
      defaults.setBool(false, forKey: "loadingOAuthToken")
      if let completionHandler = self.OAuthTokenCompletionHandler {
        let error = NSError(domain: GitHubAPIManager.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not create an OAuth authorization URL", NSLocalizedRecoverySuggestionErrorKey: "Please retry your request"])
        completionHandler(error)
      }
      return nil
    }
    
    return authURL
  }
  
  func processOAuthStep1Response(url: NSURL) {
    let components = NSURLComponents(URL: url, resolvingAgainstBaseURL: false)
    var code:String?
    if let queryItems = components?.queryItems {
      for queryItem in queryItems {
        if (queryItem.name.lowercaseString == "code") {
          code = queryItem.value
          break
        }
      }
    }
    if let receivedCode = code {
      swapAuthCodeForToken(receivedCode)
    } else {
      // no code in URL that we launched with
      let defaults = NSUserDefaults.standardUserDefaults()
      defaults.setBool(false, forKey: "loadingOAuthToken")
      
      if let completionHandler = self.OAuthTokenCompletionHandler {
        let noCodeInResponseError = NSError(domain: GitHubAPIManager.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not obtain an OAuth code", NSLocalizedRecoverySuggestionErrorKey: "Please retry your request"])
        completionHandler(noCodeInResponseError)
      }
    }
  }
  
  func swapAuthCodeForToken(receivedCode: String) {
    let getTokenPath:String = "https://github.com/login/oauth/access_token"
    let tokenParams = ["client_id": clientID, "client_secret": clientSecret, "code": receivedCode]
    let jsonHeader = ["Accept": "application/json"]
    Alamofire.request(.POST, getTokenPath, parameters: tokenParams, headers: jsonHeader)
      .responseString { response in
        if let error = response.result.error {
          let defaults = NSUserDefaults.standardUserDefaults()
          defaults.setBool(false, forKey: "loadingOAuthToken")
          
          if let completionHandler = self.OAuthTokenCompletionHandler {
            completionHandler(error)
          }
          return
        }
        print(response.result.value)
        if let receivedResults = response.result.value, jsonData = receivedResults.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false) {
          let jsonResults = JSON(data: jsonData)
          for (key, value) in jsonResults {
            switch key {
            case "access_token":
              self.OAuthToken = value.string
            case "scope":
              // TODO: verify scope
              print("SET SCOPE")
            case "token_type":
              // TODO: verify is bearer
              print("CHECK IF BEARER")
            default:
              print("got more than I expected from the OAuth token exchange")
              print(key)
            }
          }
        }
        
        let defaults = NSUserDefaults.standardUserDefaults()
        defaults.setBool(false, forKey: "loadingOAuthToken")
        
        if let completionHandler = self.OAuthTokenCompletionHandler {
          if (self.hasOAuthToken()) {
            completionHandler(nil)
          } else  {
            let noOAuthError = NSError(domain: GitHubAPIManager.ErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not obtain an OAuth token", NSLocalizedRecoverySuggestionErrorKey: "Please retry your request"])
            completionHandler(noOAuthError)
          }
        }
    }
  }
  
  // MARK: - OAuth calls
  func printMyStarredGistsWithOAuth2() -> Void {
    let starredGistsRequest = alamofireManager.request(GistRouter.GetMyStarred())
      .responseString { response in
        guard response.result.error == nil else {
          print(response.result.error!)
          GitHubAPIManager.sharedInstance.OAuthToken = nil
          return
        }
        if let receivedString = response.result.value {
          print(receivedString)
        }
    }
    debugPrint(starredGistsRequest)
  }
  
  // MARK: - Public Gists
  func printPublicGists() -> Void {
    alamofireManager.request(GistRouter.GetPublic())
      .responseString { response in
        if let receivedString = response.result.value {
          print(receivedString)
        }
    }
  }
  
  private func handleUnauthorizedResponse() -> NSError {
    self.OAuthToken = nil
    let lostOAuthError = NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Not Logged In", NSLocalizedRecoverySuggestionErrorKey: "Please re-enter your GitHub credentials"])
    return lostOAuthError
  }
  
  func getGists(urlRequest: URLRequestConvertible, completionHandler: (Result<[Gist], NSError>, String?) -> Void) {
    alamofireManager.request(urlRequest)
      .validate()
      .isUnauthorized { response in
        if let unauthorized = response.result.value where unauthorized == true {
          let lostOAuthError = self.handleUnauthorizedResponse()
          completionHandler(.Failure(lostOAuthError), nil)
          return // don't bother with .responseArray, we didn't get any data
        }
      }
      .responseArray { (response:Response<[Gist], NSError>) in
        guard response.result.error == nil,
          let gists = response.result.value else {
            print(response.result.error)
            completionHandler(response.result, nil)
            return
        }
        
        // need to figure out if this is the last page
        // check the link header, if present
        let next = self.getNextPageFromHeaders(response.response)
        completionHandler(.Success(gists), next)
    }
  }
  
  func getPublicGists(pageToLoad: String?, completionHandler: (Result<[Gist], NSError>, String?) -> Void) {
    if let urlString = pageToLoad {
      getGists(GistRouter.GetAtPath(urlString), completionHandler: completionHandler)
    } else {
      getGists(GistRouter.GetPublic(), completionHandler: completionHandler)
    }
  }
  
  func getMyStarredGists(pageToLoad: String?, completionHandler: (Result<[Gist], NSError>, String?) -> Void) {
    if let urlString = pageToLoad {
      getGists(GistRouter.GetAtPath(urlString), completionHandler: completionHandler)
    } else {
      getGists(GistRouter.GetMyStarred(), completionHandler: completionHandler)
    }
  }
  
  func getMyGists(pageToLoad: String?, completionHandler: (Result<[Gist], NSError>, String?) -> Void) {
    if let urlString = pageToLoad {
      getGists(GistRouter.GetAtPath(urlString), completionHandler: completionHandler)
    } else {
      getGists(GistRouter.GetMine(), completionHandler: completionHandler)
    }
  }
  
  // MARK: - Images
  func imageFromURLString(imageURLString: String, completionHandler: (UIImage?, NSError?) -> Void) {
    alamofireManager.request(.GET, imageURLString)
      .response { (request, response, data, error) in
        // use the generic response serializer that returns NSData
        if data == nil {
          completionHandler(nil, nil)
          return
        }
        let image = UIImage(data: data! as NSData)
        completionHandler(image, nil)
    }
  }
  
  // MARK: - Pagination
  private func getNextPageFromHeaders(response: NSHTTPURLResponse?) -> String? {
    if let linkHeader = response?.allHeaderFields["Link"] as? String {
      /* looks like:
      <https://api.github.com/user/20267/gists?page=2>; rel="next", <https://api.github.com/user/20267/gists?page=6>; rel="last"
      */
      // so split on "," the  on  ";"
      let components = linkHeader.characters.split {$0 == ","}.map { String($0) }
      // now we have 2 lines like '<https://api.github.com/user/20267/gists?page=2>; rel="next"'
      // So let's get the URL out of there:
      for item in components {
        // see if it's "next"
        let rangeOfNext = item.rangeOfString("rel=\"next\"", options: [])
        if rangeOfNext != nil {
          let rangeOfPaddedURL = item.rangeOfString("<(.*)>;", options: .RegularExpressionSearch)
          if let range = rangeOfPaddedURL {
            let nextURL = item.substringWithRange(range)
            // strip off the < and >;
            let startIndex = nextURL.startIndex.advancedBy(1) //advance as much as you like
            let endIndex = nextURL.endIndex.advancedBy(-2)
            let urlRange = startIndex..<endIndex
            return nextURL.substringWithRange(urlRange)
          }
        }
      }
    }
    return nil
  }
  
  // MARK: Starring / Unstarring / Star status
  func isGistStarred(gistId: String, completionHandler: Result<Bool, NSError> -> Void) {
    alamofireManager.request(GistRouter.IsStarred(gistId))
      .validate(statusCode: [204])
      .isUnauthorized { response in
        if let unauthorized = response.result.value where unauthorized == true {
          let lostOAuthError = self.handleUnauthorizedResponse()
          completionHandler(.Failure(lostOAuthError))
          return // don't bother with .responseArray, we didn't get any data
        }
      }
      .response { (request, response, data, error) in
        // 204 if starred, 404 if not
        if let error = error {
          print(error)
          if response?.statusCode == 404 {
            completionHandler(.Success(false))
            return
          }
          completionHandler(.Failure(error))
          return
        }
        completionHandler(.Success(true))
    }
  }
  
  func starGist(gistId: String, completionHandler: (NSError?) -> Void) {
    alamofireManager.request(GistRouter.Star(gistId))
      .isUnauthorized { response in
        if let unauthorized = response.result.value where unauthorized == true {
          let lostOAuthError = self.handleUnauthorizedResponse()
          completionHandler(lostOAuthError)
          return // don't bother with .responseArray, we didn't get any data
        }
      }
      .response { (request, response, data, error) in
        if let error = error {
          print(error)
          return
        }
        completionHandler(error)
    }
  }
  
  func unstarGist(gistId: String, completionHandler: (NSError?) -> Void) {
    alamofireManager.request(GistRouter.Unstar(gistId))
      .isUnauthorized { response in
        if let unauthorized = response.result.value where unauthorized == true {
          let lostOAuthError = self.handleUnauthorizedResponse()
          completionHandler(lostOAuthError)
          return // don't bother with .responseArray, we didn't get any data
        }
      }
      .response { (request, response, data, error) in
        if let error = error {
          print(error)
          return
        }
        completionHandler(error)
    }
  }
  
  
  // MARK: Delete and Add
  func deleteGist(gistId: String, completionHandler: (NSError?) -> Void) {
    alamofireManager.request(GistRouter.Delete(gistId))
      .isUnauthorized { response in
        if let unauthorized = response.result.value where unauthorized == true {
          let lostOAuthError = self.handleUnauthorizedResponse()
          completionHandler(lostOAuthError)
          return // don't bother with .responseArray, we didn't get any data
        }
      }
      .response { (request, response, data, error) in
        if let error = error {
          print(error)
          return
        }
        completionHandler(error)
    }
  }
  
  func createNewGist(description: String, isPublic: Bool, files: [File], completionHandler: Result<Bool, NSError> -> Void) {
    let publicString: String
    if isPublic {
      publicString = "true"
    } else {
      publicString = "false"
    }
    
    var filesDictionary = [String: AnyObject]()
    for file in files {
      if let name = file.filename, contents = file.contents {
        filesDictionary[name] = ["content": contents]
      }
    }
    let parameters:[String: AnyObject] = [
      "description": description,
      "isPublic": publicString,
      "files" : filesDictionary
    ]
    
    alamofireManager.request(GistRouter.Create(parameters))
      .isUnauthorized { response in
        if let unauthorized = response.result.value where unauthorized == true {
          let lostOAuthError = self.handleUnauthorizedResponse()
          completionHandler(.Failure(lostOAuthError))
          return // don't bother with .responseArray, we didn't get any data
        }
      }
      .response { (request, response, data, error) in
        if let error = error {
          print(error)
          completionHandler(.Success(false))
          return
        }
        self.clearCache()
        completionHandler(.Success(true))
    }
  }
}