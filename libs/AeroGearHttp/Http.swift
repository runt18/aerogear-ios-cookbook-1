/*
* JBoss, Home of Professional Open Source.
* Copyright Red Hat, Inc., and individual contributors
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Foundation

/**
The HTTP method verb

- GET:    GET http verb
- HEAD:   HEAD http verb
- DELETE:  DELETE http verb
- POST:   POST http verb
- PUT:    PUT http verb
*/
public enum HttpMethod: String {
    case GET = "GET"
    case HEAD = "HEAD"
    case DELETE = "DELETE"
    case POST = "POST"
    case PUT = "PUT"
}

/**
The file request type

- Download: Download request
- Upload:   Upload request
*/
enum FileRequestType {
    case Download(String?)
    case Upload(UploadType)
}

/**
The Upload enum type

- Data:   for a generic NSData object
- File:   for File passing the URL of the local file to upload
- Stream:  for a Stream request passing the actual NSInputStream
*/
enum UploadType {
    case Data(NSData)
    case File(NSURL)
    case Stream(NSInputStream)
}



/**
Main class for performing HTTP operations across RESTful resources
*/
public class Http<Serializer: ResponseSerializer> {
    public typealias ProgressBlock = (Int64, Int64, Int64) -> Void
    public typealias CompletionBlock = (AnyObject?, NSError?) -> Void
    
    var baseURL: String?
    var session: NSURLSession
    var requestSerializer: RequestSerializer
    var responseSerializer: Serializer
    var authzModule:  AuthzModule?
    
    private var delegate: SessionDelegate<Serializer>;
    
    /**
    Initialize an HTTP object
    
    :param: baseURL              the remote base URL of the application (optional)
    :param: sessionConfig       the SessionConfiguration object (by default it uses a defaultSessionConfiguration)
    :param: requestSerializer   the actual request serializer to use when performing requests
    :param: responseSerializer the actual response serializer to use upon receiving a response
    
    :returns: the newly intitialized HTTP object
    */
    public init(baseURL: String?,
                    sessionConfig: NSURLSessionConfiguration ,
                    requestSerializer: JsonRequestSerializer,
                    responseSerializer: Serializer) {
        self.baseURL = baseURL
        self.delegate = SessionDelegate()
        self.session = NSURLSession(configuration: sessionConfig, delegate: self.delegate, delegateQueue: NSOperationQueue.mainQueue())
        self.requestSerializer = requestSerializer
        self.responseSerializer = responseSerializer
    }
    
//    deinit {
//        self.session.invalidateAndCancel()
//    }
    
    /**
    Gateway to perform different http requests including multipart
    
    :param: url               the url of the resource
    :param: parameters  the request parameters
    :param: method       the method to be used,
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    private func request(url: String, parameters: [String: AnyObject]? = nil,  method:HttpMethod, completionHandler: CompletionBlock) {
        let block: () -> Void =  {
            var finalURL = self.calculateURL(self.baseURL, url: url)
            
            var request: NSURLRequest
            
            // care for multipart request is multipart data are set
            if (self.hasMultiPartData(parameters)) {
                request = self.requestSerializer.multipartRequest(finalURL, method: method, parameters: parameters, headers: self.authzModule?.authorizationFields())
            } else {
                request = self.requestSerializer.request(finalURL, method: method, parameters: parameters, headers: self.authzModule?.authorizationFields())
            }

            let task = self.session.dataTaskWithRequest(request);
            let delegate = TaskDataDelegate<Serializer>()
            delegate.completionHandler = completionHandler
            delegate.responseSerializer = self.responseSerializer;
            
            self.delegate[task] = delegate
            task.resume()
        }
        
        // cater for authz and pre-authorize prior to performing request
        if (self.authzModule != nil) {
            self.authzModule?.requestAccess({ (response, error ) in
                // if there was an error during authz, no need to continue
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }
                // ..otherwise proceed normally
                block();
            })
        } else {
            block()
        }
    }
    
    /**
    Gateway to perform different file requests either download or upload
    
    :param: url               the url of the resource
    :param: parameters  the request parameters
    :param: method       the method to be used,
    :param: type             the file request type
    :param: progress        a block that will be invoked to report progress during either download or upload
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    private func fileRequest(url: String, parameters: [String: AnyObject]? = nil,  method: HttpMethod,  type: FileRequestType, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        
        let block: () -> Void  = {
            var finalURL = self.calculateURL(self.baseURL, url: url)
            let request = self.requestSerializer.request(finalURL, method: method, parameters: parameters, headers: self.authzModule?.authorizationFields())
            
            var task: NSURLSessionTask

            switch type {
                case .Download(let destinationDirectory):
                    task = self.session.downloadTaskWithRequest(request)
                    
                    let delegate = TaskDownloadDelegate<Serializer>()
                    delegate.downloadProgress = progress
                    delegate.destinationDirectory = destinationDirectory;
                    delegate.completionHandler = completionHandler 

                    self.delegate[task] = delegate

                case .Upload(let uploadType):
                    switch uploadType {
                        case .Data(let data):
                            task = self.session.uploadTaskWithRequest(request, fromData: data)
                        case .File(let url):
                            task = self.session.uploadTaskWithRequest(request, fromFile: url)
                        case .Stream(let stream):
                            task = self.session.uploadTaskWithStreamedRequest(request)
                    }

                let delegate = TaskUploadDelegate<Serializer>()
                delegate.uploadProgress = progress
                delegate.completionHandler = completionHandler
                    
                self.delegate[task] = delegate
            }
            
            task.resume()
        }
        
        // cater for authz and pre-authorize prior to performing request
        if (self.authzModule != nil) {
            self.authzModule?.requestAccess({ (response, error ) in
                // if there was an error during authz, no need to continue
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }
                // ..otherwise proceed normally
                block();
            })
        } else {
            block()
        }
    }
    
    /**
    performs an HTTP GET request
    
    :param: url               the url of the resource
    :param: parameters  the request parameters
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func GET(url: String, parameters: [String: AnyObject]? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters,  method:.GET, completionHandler: completionHandler)
    }
    
    /**
    performs an HTTP POST request
    
    :param: url               the url of the resource
    :param: parameters   the request parameters
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func POST(url: String, parameters: [String: AnyObject]? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters, method:.POST, completionHandler: completionHandler)
    }
    
    /**
    performs an HTTP PUT request
    
    :param: url               the url of the resource
    :param: parameters   the request parameters
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func PUT(url: String, parameters: [String: AnyObject]? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters, method:.PUT, completionHandler: completionHandler)
    }
    
    /**
    performs an HTTP DELETE request
    
    :param: url               the url of the resource
    :param: parameters  the request parameters
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func DELETE(url: String, parameters: [String: AnyObject]? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters, method:.DELETE, completionHandler: completionHandler)
    }
    
    /**
    performs an HTTP HEAD request
    
    :param: url               the url of the resource
    :param: parameters   the request parameters
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func HEAD(url: String, parameters: [String: AnyObject]? = nil, completionHandler: CompletionBlock) {
        request(url, parameters: parameters, method:.HEAD, completionHandler: completionHandler)
    }

    /**
    Request to download a file
    
    :param: url                      the URL of the downloadable resource
    :param: destinationDirectory the destination directory where the file would be stored, if not specified application's default '.Documents' directory would be used
    :param: parameters          the request parameters
    :param: method               the method to be used, by default a .GET request
    :param: progress              a block that will be invoked to report progress during download
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func download(url: String,  destinationDirectory: String? = nil, parameters: [String: AnyObject]? = nil,  method: HttpMethod = .GET, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, type: .Download(destinationDirectory), progress: progress, completionHandler: completionHandler)
    }

    /**
    Request to upload a file using an NURL of a local file
    
    :param: url              the URL to upload resource into
    :param: file              the URL of the local file to be uploaded
    :param: parameters  the request parameters
    :param: method       the method to be used, by default a .POST request
    :param: progress      a block that will be invoked to report progress during upload
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func upload(url: String,  file: NSURL, parameters: [String: AnyObject]? = nil,  method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, type: .Upload(.File(file)), progress: progress, completionHandler: completionHandler)
    }
    
    /**
    Request to upload a file using a raw NSData object
    
    :param: url              the URL to upload resource into
    :param: data            the data to be uploaded
    :param: parameters  the request parameters
    :param: method       the method to be used, by default a .POST request
    :param: progress      a block that will be invoked to report progress during upload
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func upload(url: String,  data: NSData, parameters: [String: AnyObject]? = nil, method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, type: .Upload(.Data(data)), progress: progress, completionHandler: completionHandler)
    }
    
    /**
    Request to upload a file using an NSInputStream object
    
    :param: url              the URL to upload resource into
    :param: stream         the stream that will be used for uploading
    :param: parameters  the request parameters
    :param: method       the method to be used, by default a .POST request
    :param: progress      a block that will be invoked to report progress during upload
    :param: completionHandler A block object to be executed when the request operation finishes successfully. This block has no return value and takes two arguments: The object created from the response data of request and the `NSError` object describing the network or parsing error that occurred.
    */
    public func upload(url: String,  stream: NSInputStream,  parameters: [String: AnyObject]? = nil, method: HttpMethod = .POST, progress: ProgressBlock?, completionHandler: CompletionBlock) {
        fileRequest(url, parameters: parameters, method: method, type: .Upload(.Stream(stream)), progress: progress, completionHandler: completionHandler)
    }
    
    
    // MARK: Private API
    
    // MARK: SessionDelegate


    // MARK: Utility methods
    public func calculateURL(baseURL: String?,  var url: String) -> NSURL {
        if (baseURL == nil || url.hasPrefix("http")) {
            return NSURL(string: url)!
        }
        
        var finalURL = NSURL(string: baseURL!)!
        if (url.hasPrefix("/")) {
            url = url.substringFromIndex(advance(url.startIndex, 0))
        }
            
        return finalURL.URLByAppendingPathComponent(url);
    }
    
    public func hasMultiPartData(parameters: [String: AnyObject]?) -> Bool {
        if (parameters == nil) {
            return false
        }
        
        var isMultiPart = false
        for (_, value) in parameters! {
            if value is MultiPartData {
                isMultiPart = true
                break
            }
        }
        
        return isMultiPart
    }
}
// MARK: NSURLSessionTaskDelegate
private class TaskDelegate<Serializer: ResponseSerializer>: NSObject, NSURLSessionTaskDelegate {
    
    var data: NSData? { return nil }
    var completionHandler:  ((AnyObject?, NSError?) -> Void)?
    var responseSerializer: Serializer?
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, willPerformHTTPRedirection response: NSHTTPURLResponse!, newRequest request: NSURLRequest!, completionHandler: ((NSURLRequest!) -> Void)!) {
        
        completionHandler(request)
    }
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, didReceiveChallenge challenge: NSURLAuthenticationChallenge!, completionHandler: ((NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void)!) {
        var disposition: NSURLSessionAuthChallengeDisposition = .PerformDefaultHandling
        var credential: NSURLCredential?
        
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            credential = NSURLCredential(forTrust: challenge.protectionSpace.serverTrust)
            disposition = .UseCredential
        }
        completionHandler(disposition, credential)
    }
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, needNewBodyStream completionHandler: ((NSInputStream!) -> Void)!) {
    }
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, didCompleteWithError error: NSError!) {
        if error != nil {
            completionHandler?(nil, error)
            return
        }
        
        var response = task.response as NSHTTPURLResponse
        
        if  let downloadTask = task as? NSURLSessionDownloadTask {
            completionHandler?(response, error)
            return
        }
        
        if let uploadTask = task as? NSURLSessionUploadTask {
            completionHandler?(response, error)
            return
        }
        
        var error: NSError?
        var isValid = self.responseSerializer?.validateResponse(response, data: data!, error: &error)
        
        if (isValid == false) {
            completionHandler?(nil, error)
            return
        }
        
        if (data != nil) {
            var responseObject: Serializer.Model? = self.responseSerializer?.response(response, data: data!)
            //TODO: don't like this casting
            completionHandler?(responseObject as NSObject, nil)
        }
    }
}

// MARK: NSURLSessionDataDelegate
private class TaskDataDelegate<Serializer: ResponseSerializer>: TaskDelegate<Serializer>, NSURLSessionDataDelegate {
    
    private var mutableData: NSMutableData
    override var data: NSData? {
        return self.mutableData
    }
    
    override init() {
        self.mutableData = NSMutableData()
    }
    
    func URLSession(session: NSURLSession!, dataTask: NSURLSessionDataTask!, didReceiveData data: NSData!) {
        self.mutableData.appendData(data)
    }
    
    func URLSession(session: NSURLSession!, dataTask: NSURLSessionDataTask!, willCacheResponse proposedResponse: NSCachedURLResponse!, completionHandler: ((NSCachedURLResponse!) -> Void)!) {
        var cachedResponse = proposedResponse
        completionHandler(cachedResponse)
    }
}

// MARK: NSURLSessionDownloadDelegate
private class TaskDownloadDelegate<Serializer: ResponseSerializer>: TaskDelegate<Serializer>, NSURLSessionDownloadDelegate {
    
    var downloadProgress: ((Int64, Int64, Int64) -> Void)?
    var resumeData: NSData?
    var destinationDirectory: String?
    
    func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didFinishDownloadingToURL location: NSURL) {
        let filename = downloadTask.response?.suggestedFilename
        
        // calculate final destination
        var finalDestination: NSURL
        if (destinationDirectory == nil) {  // use 'default documents' directory if not set
            // use default documents directory
            var documentsDirectory  = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)[0] as NSURL
            finalDestination = documentsDirectory.URLByAppendingPathComponent(filename!)
        } else {
            // check that the directory exists
            var path = destinationDirectory?.stringByAppendingPathComponent(filename!)
            finalDestination = NSURL(fileURLWithPath: path!)!
        }
        
        NSFileManager.defaultManager().moveItemAtURL(location, toURL: finalDestination, error: nil)
    }
    
    func URLSession(session: NSURLSession!, downloadTask: NSURLSessionDownloadTask!, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        self.downloadProgress?(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
    }
    
    func URLSession(session: NSURLSession!, downloadTask: NSURLSessionDownloadTask!, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
    }
}

// MARK: NSURLSessionTaskDelegate
private class TaskUploadDelegate<Serializer: ResponseSerializer>: TaskDataDelegate<Serializer> {
    
    var uploadProgress: ((Int64, Int64, Int64) -> Void)?
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        self.uploadProgress?(bytesSent, totalBytesSent, totalBytesExpectedToSend)
    }
}
class SessionDelegate<Serializer: ResponseSerializer>: NSObject, NSURLSessionDelegate,  NSURLSessionTaskDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate {
    
    private var delegates: [Int:  TaskDelegate<Serializer>]
    
    private subscript(task: NSURLSessionTask) -> TaskDelegate<Serializer>? {
        get {
            return self.delegates[task.taskIdentifier]
        }
        
        set (newValue) {
            self.delegates[task.taskIdentifier] = newValue
        }
    }
    
    required override init() {
        self.delegates = Dictionary()
        super.init()
    }
    
    func URLSession(session: NSURLSession!, didBecomeInvalidWithError error: NSError!) {
        // TODO
    }
    
    func URLSession(session: NSURLSession!, didReceiveChallenge challenge: NSURLAuthenticationChallenge!, completionHandler: ((NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void)!) {
        
        // TODO: handle authentication
        completionHandler(.PerformDefaultHandling, nil)
    }
    
    func URLSessionDidFinishEventsForBackgroundURLSession(session: NSURLSession!) {
        // TODO
    }
    
    // MARK: NSURLSessionTaskDelegate
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, willPerformHTTPRedirection response: NSHTTPURLResponse!, newRequest request: NSURLRequest!, completionHandler: ((NSURLRequest!) -> Void)!) {
        
        if let delegate = self[task] {
            delegate.URLSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
        }
    }
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, didReceiveChallenge challenge: NSURLAuthenticationChallenge!, completionHandler: ((NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void)!) {
        if let delegate = self[task] {
            delegate.URLSession(session, task: task, didReceiveChallenge: challenge, completionHandler: completionHandler)
        } else {
            self.URLSession(session, didReceiveChallenge: challenge, completionHandler: completionHandler)
        }
    }
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, needNewBodyStream completionHandler: ((NSInputStream!) -> Void)!) {
        if let delegate = self[task] {
            delegate.URLSession(session, task: task, needNewBodyStream: completionHandler)
        }
    }
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if let delegate = self[task] as? TaskUploadDelegate {
            delegate.URLSession(session, task: task, didSendBodyData: bytesSent, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
        }
    }
    
    func URLSession(session: NSURLSession!, task: NSURLSessionTask!, didCompleteWithError error: NSError!) {
        if let delegate = self[task] {
            delegate.URLSession(session, task: task, didCompleteWithError: error)
        }
    }
    
    // MARK: NSURLSessionDataDelegate
    
    func URLSession(session: NSURLSession!, dataTask: NSURLSessionDataTask!, didReceiveResponse response: NSURLResponse!, completionHandler: ((NSURLSessionResponseDisposition) -> Void)!) {
        completionHandler(.Allow)
    }
    
    func URLSession(session: NSURLSession!, dataTask: NSURLSessionDataTask!, didBecomeDownloadTask downloadTask: NSURLSessionDownloadTask!) {
        let downloadDelegate = TaskDownloadDelegate<Serializer>()
        self[downloadTask] = downloadDelegate
    }
    
    func URLSession(session: NSURLSession!, dataTask: NSURLSessionDataTask!, didReceiveData data: NSData!) {
        if let delegate = self[dataTask] as? TaskDataDelegate {
            delegate.URLSession(session, dataTask: dataTask, didReceiveData: data)
        }
    }
    
    func URLSession(session: NSURLSession!, dataTask: NSURLSessionDataTask!, willCacheResponse proposedResponse: NSCachedURLResponse!, completionHandler: ((NSCachedURLResponse!) -> Void)!) {
        
        completionHandler(proposedResponse)
    }
    
    // MARK: NSURLSessionDownloadDelegate
    
    func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didFinishDownloadingToURL location: NSURL) {
        if let delegate = self[downloadTask] as? TaskDownloadDelegate {
            delegate.URLSession(session, downloadTask: downloadTask, didFinishDownloadingToURL: location)
        }
    }
    
    func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let delegate = self[downloadTask] as? TaskDownloadDelegate {
            delegate.URLSession(session, downloadTask: downloadTask, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
    }
    
    func URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        if let delegate = self[downloadTask] as? TaskDownloadDelegate {
            delegate.URLSession(session, downloadTask: downloadTask, didResumeAtOffset: fileOffset, expectedTotalBytes: expectedTotalBytes)
        }
    }
}

