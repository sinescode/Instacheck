import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:excel/excel.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Instacheck',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  @override
  _MainScreenState createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _currentTab = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      setState(() {
        _currentTab = _tabController.index;
      });
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Instacheck'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'File'),
            Tab(text: 'Text'),
            Tab(text: 'Converter'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          FileProcessingTab(),
          TextProcessingTab(),
          ConverterTab(),
        ],
      ),
    );
  }
}

class FileProcessingTab extends StatefulWidget {
  @override
  _FileProcessingTabState createState() => _FileProcessingTabState();
}

class _FileProcessingTabState extends State<FileProcessingTab> {
  String? _selectedFileName;
  PlatformFile? _selectedFile;
  bool _processing = false;
  bool _showProgress = false;
  bool _showDownloadButton = false;
  bool _showCancelButton = false;
  int _processedCount = 0;
  int _activeCount = 0;
  int _availableCount = 0;
  int _errorCount = 0;
  int _cancelledCount = 0;
  int _totalCount = 0;
  List<String> _usernames = [];
  List<Map<String, dynamic>> _activeAccounts = [];
  List<ResultItem> _results = [];
  String _originalFileName = "";
  late StreamController<ResultItem> _resultsController;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _resultsController = StreamController<ResultItem>.broadcast();
  }

  @override
  void dispose() {
    _resultsController.close();
    super.dispose();
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
    );

    if (result != null) {
      setState(() {
        _selectedFile = result.files.first;
        _selectedFileName = _selectedFile!.name;
        _originalFileName = _selectedFileName!.substring(0, _selectedFileName!.lastIndexOf('.'));
      });
    }
  }

  Future<void> _startProcessing() async {
    if (_selectedFile == null) {
      _showError("Please select a file first");
      return;
    }

    setState(() {
      _processing = true;
      _showProgress = true;
      _showDownloadButton = false;
      _showCancelButton = true;
      _resetStats();
    });

    // Read file content
    String content = String.fromCharCodes(_selectedFile!.bytes!);
    
    if (_selectedFileName!.endsWith('.txt')) {
      _usernames = content.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
    } else if (_selectedFileName!.endsWith('.json')) {
      try {
        List<dynamic> jsonList = json.decode(content);
        _usernames = jsonList.map((item) => item['username'].toString()).toList();
      } catch (e) {
        _showError("Invalid JSON format: $e");
        setState(() {
          _processing = false;
          _showProgress = false;
        });
        return;
      }
    }

    setState(() {
      _totalCount = _usernames.length;
    });

    _processUsernames();
  }

  void _processUsernames() async {
    _cancelled = false;
    const concurrentLimit = 5;
    final semaphore = Semaphore(concurrentLimit);
    
    List<Future> futures = [];
    
    for (String username in _usernames) {
      if (_cancelled) break;
      
      futures.add(_checkUsername(username, semaphore));
      await Future.delayed(Duration(milliseconds: 100)); // Stagger requests
    }
    
    await Future.wait(futures);
    
    if (!_cancelled) {
      setState(() {
        _processing = false;
        _showCancelButton = false;
        _showDownloadButton = _activeAccounts.isNotEmpty;
      });
      _showSuccess("Processing completed! Found ${_activeAccounts.length} active accounts.");
    }
  }

  Future<void> _checkUsername(String username, Semaphore semaphore) async {
    await semaphore.acquire();
    
    if (_cancelled) {
      semaphore.release();
      return;
    }
    
    const maxRetries = 10;
    const initialDelay = 1000;
    const maxDelay = 60000;
    int retryCount = 0;
    int delayMs = initialDelay;
    final random = Random();
    
    while (retryCount < maxRetries && !_cancelled) {
      try {
        final url = "https://i.instagram.com/api/v1/users/web_profile_info/?username=$username";
        
        final response = await http.get(Uri.parse(url), headers: {
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Safari/537.36",
          "x-ig-app-id": "936619743392459",
          "Accept": "*/*",
          "Accept-Language": "en-US,en;q=0.9",
          "Referer": "https://www.instagram.com/",
          "Origin": "https://www.instagram.com",
          "Sec-Fetch-Site": "same-origin"
        });
        
        if (response.statusCode == 404) {
          // User not found (available)
          _updateResult("AVAILABLE", "$username - Available", username);
          semaphore.release();
          return;
        } else if (response.statusCode == 200) {
          // User found, check if active
          final jsonData = json.decode(response.body);
          final userData = jsonData['data']?['user'];
          
          if (userData != null) {
            // Active account
            _updateResult("ACTIVE", "$username - Active", username);
            _activeAccounts.add({
              'username': username,
              'data': userData
            });
          } else {
            // Available username
            _updateResult("AVAILABLE", "$username - Available", username);
          }
          semaphore.release();
          return;
        } else {
          // Other status code, retry
          retryCount++;
          _updateStatus("Retry $retryCount/$maxRetries for $username (Status: ${response.statusCode})", username);
        }
      } catch (e) {
        retryCount++;
        String errorMsg = e.toString();
        if (errorMsg.length > 30) errorMsg = errorMsg.substring(0, 30) + "...";
        _updateStatus("Retry $retryCount/$maxRetries for $username ($errorMsg)", username);
      }
      
      // Wait before retrying with exponential backoff and jitter
      await Future.delayed(Duration(milliseconds: delayMs));
      delayMs = min(maxDelay, (delayMs * 1.5 + random.nextInt(1000)).toInt());
    }
    
    if (!_cancelled) {
      _updateResult("ERROR", "$username - Error (Max retries exceeded)", username);
    }
    
    semaphore.release();
  }

  void _updateResult(String status, String message, String username) {
    setState(() {
      _processedCount++;
      
      switch (status) {
        case "ACTIVE":
          _activeCount++;
          break;
        case "AVAILABLE":
          _availableCount++;
          break;
        case "ERROR":
          _errorCount++;
          break;
        case "CANCELLED":
          _cancelledCount++;
          break;
      }
      
      _results.insert(0, ResultItem(status, message));
    });
    
    _updateProgress();
  }

  void _updateStatus(String message, [String? username]) {
    setState(() {
      _results.insert(0, ResultItem("INFO", message));
    });
  }

  void _updateProgress() {
    setState(() {});
  }

  void _resetStats() {
    setState(() {
      _processedCount = 0;
      _activeCount = 0;
      _availableCount = 0;
      _errorCount = 0;
      _cancelledCount = 0;
      _activeAccounts.clear();
      _results.clear();
    });
  }

  void _cancelProcessing() {
    setState(() {
      _cancelled = true;
      _processing = false;
      _showCancelButton = false;
      _showDownloadButton = _activeAccounts.isNotEmpty;
    });
    _updateStatus("Processing cancelled by user");
    _showInfo("Processing cancelled");
  }

  Future<void> _downloadResults() async {
    if (_activeAccounts.isEmpty) {
      _showError("No active accounts to download");
      return;
    }
    
    // Request storage permission
    var status = await Permission.storage.status;
    if (!status.isGranted) {
      status = await Permission.storage.request();
    }
    
    if (status.isGranted) {
      final directory = await getExternalStorageDirectory();
      final timestamp = DateTime.now().toString().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
      final file = File('${directory!.path}/final_${_originalFileName}_$timestamp.json');
      
      await file.writeAsString(json.encode(_activeAccounts));
      
      _showSuccess("Results saved successfully! (${_activeAccounts.length} active accounts)");
      OpenFile.open(file.path);
    } else {
      _showError("Storage permission denied");
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      )
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      )
    );
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // File selection
          ElevatedButton.icon(
            onPressed: _processing ? null : _pickFile,
            icon: Icon(_selectedFileName != null ? Icons.check_circle : Icons.attach_file),
            label: Text(_selectedFileName ?? "Select File (JSON/TXT)"),
            style: ElevatedButton.styleFrom(
              backgroundColor: _selectedFileName != null ? Colors.green[50] : null,
              foregroundColor: _selectedFileName != null ? Colors.green[700] : null,
            ),
          ),
          SizedBox(height: 16),
          
          // Start processing button
          ElevatedButton(
            onPressed: _processing ? null : _startProcessing,
            child: Text("Start Processing"),
          ),
          SizedBox(height: 16),
          
          // Progress section
          if (_showProgress) ...[
            LinearProgressIndicator(
              value: _totalCount > 0 ? _processedCount / _totalCount : 0,
            ),
            SizedBox(height: 8),
            Text("Progress: $_processedCount/$_totalCount (${_totalCount > 0 ? (_processedCount * 100 / _totalCount).round() : 0}%)"),
            SizedBox(height: 16),
            
            // Stats
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatCard("Active", _activeCount, Colors.red),
                _buildStatCard("Available", _availableCount, Colors.green),
                _buildStatCard("Error", _errorCount, Colors.orange),
                _buildStatCard("Total", _totalCount, Colors.blue),
              ],
            ),
            SizedBox(height: 16),
            
            // Results list
            Container(
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
              child: ListView.builder(
                reverse: true,
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final item = _results[index];
                  return ResultListItem(item: item);
                },
              ),
            ),
            SizedBox(height: 16),
            
            // Action buttons
            Row(
              children: [
                if (_showCancelButton)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _cancelProcessing,
                      child: Text("Cancel"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    ),
                  ),
                if (_showCancelButton) SizedBox(width: 16),
                if (_showDownloadButton)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _downloadResults,
                      child: Text("Download Results"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
  
  Widget _buildStatCard(String title, int count, Color color) {
    return Column(
      children: [
        Text(title, style: TextStyle(fontSize: 12)),
        Text("$count", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}

class TextProcessingTab extends StatefulWidget {
  @override
  _TextProcessingTabState createState() => _TextProcessingTabState();
}

class _TextProcessingTabState extends State<TextProcessingTab> {
  final TextEditingController _textController = TextEditingController();
  bool _processing = false;
  bool _showProgress = false;
  bool _showDownloadButton = false;
  bool _showCancelButton = false;
  int _processedCount = 0;
  int _activeCount = 0;
  int _availableCount = 0;
  int _errorCount = 0;
  int _cancelledCount = 0;
  int _totalCount = 0;
  List<String> _usernames = [];
  List<Map<String, dynamic>> _activeAccounts = [];
  List<ResultItem> _results = [];
  bool _cancelled = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _startProcessing() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      _showError("Please enter at least one username");
      return;
    }

    setState(() {
      _usernames = text.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
      _processing = true;
      _showProgress = true;
      _showDownloadButton = false;
      _showCancelButton = true;
      _resetStats();
      _totalCount = _usernames.length;
    });

    _processUsernames();
  }

  void _processUsernames() async {
    _cancelled = false;
    const concurrentLimit = 5;
    final semaphore = Semaphore(concurrentLimit);
    
    List<Future> futures = [];
    
    for (String username in _usernames) {
      if (_cancelled) break;
      
      futures.add(_checkUsername(username, semaphore));
      await Future.delayed(Duration(milliseconds: 100)); // Stagger requests
    }
    
    await Future.wait(futures);
    
    if (!_cancelled) {
      setState(() {
        _processing = false;
        _showCancelButton = false;
        _showDownloadButton = _activeAccounts.isNotEmpty;
      });
      _showSuccess("Processing completed! Found ${_activeAccounts.length} active accounts.");
    }
  }

  Future<void> _checkUsername(String username, Semaphore semaphore) async {
    await semaphore.acquire();
    
    if (_cancelled) {
      semaphore.release();
      return;
    }
    
    const maxRetries = 10;
    const initialDelay = 1000;
    const maxDelay = 60000;
    int retryCount = 0;
    int delayMs = initialDelay;
    final random = Random();
    
    while (retryCount < maxRetries && !_cancelled) {
      try {
        final url = "https://i.instagram.com/api/v1/users/web_profile_info/?username=$username";
        
        final response = await http.get(Uri.parse(url), headers: {
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Safari/537.36",
          "x-ig-app-id": "936619743392459",
          "Accept": "*/*",
          "Accept-Language": "en-US,en;q=0.9",
          "Referer": "https://www.instagram.com/",
          "Origin": "https://www.instagram.com",
          "Sec-Fetch-Site": "same-origin"
        });
        
        if (response.statusCode == 404) {
          // User not found (available)
          _updateResult("AVAILABLE", "$username - Available", username);
          semaphore.release();
          return;
        } else if (response.statusCode == 200) {
          // User found, check if active
          final jsonData = json.decode(response.body);
          final userData = jsonData['data']?['user'];
          
          if (userData != null) {
            // Active account
            _updateResult("ACTIVE", "$username - Active", username);
            _activeAccounts.add({
              'username': username,
              'data': userData
            });
          } else {
            // Available username
            _updateResult("AVAILABLE", "$username - Available", username);
          }
          semaphore.release();
          return;
        } else {
          // Other status code, retry
          retryCount++;
          _updateStatus("Retry $retryCount/$maxRetries for $username (Status: ${response.statusCode})", username);
        }
      } catch (e) {
        retryCount++;
        String errorMsg = e.toString();
        if (errorMsg.length > 30) errorMsg = errorMsg.substring(0, 30) + "...";
        _updateStatus("Retry $retryCount/$maxRetries for $username ($errorMsg)", username);
      }
      
      // Wait before retrying with exponential backoff and jitter
      await Future.delayed(Duration(milliseconds: delayMs));
      delayMs = min(maxDelay, (delayMs * 1.5 + random.nextInt(1000)).toInt());
    }
    
    if (!_cancelled) {
      _updateResult("ERROR", "$username - Error (Max retries exceeded)", username);
    }
    
    semaphore.release();
  }

  void _updateResult(String status, String message, String username) {
    setState(() {
      _processedCount++;
      
      switch (status) {
        case "ACTIVE":
          _activeCount++;
          break;
        case "AVAILABLE":
          _availableCount++;
          break;
        case "ERROR":
          _errorCount++;
          break;
        case "CANCELLED":
          _cancelledCount++;
          break;
      }
      
      _results.insert(0, ResultItem(status, message));
    });
    
    _updateProgress();
  }

  void _updateStatus(String message, [String? username]) {
    setState(() {
      _results.insert(0, ResultItem("INFO", message));
    });
  }

  void _updateProgress() {
    setState(() {});
  }

  void _resetStats() {
    setState(() {
      _processedCount = 0;
      _activeCount = 0;
      _availableCount = 0;
      _errorCount = 0;
      _cancelledCount = 0;
      _activeAccounts.clear();
      _results.clear();
    });
  }

  void _cancelProcessing() {
    setState(() {
      _cancelled = true;
      _processing = false;
      _showCancelButton = false;
      _showDownloadButton = _activeAccounts.isNotEmpty;
    });
    _updateStatus("Processing cancelled by user");
    _showInfo("Processing cancelled");
  }

  Future<void> _downloadResults() async {
    if (_activeAccounts.isEmpty) {
      _showError("No active accounts to download");
      return;
    }
    
    // Request storage permission
    var status = await Permission.storage.status;
    if (!status.isGranted) {
      status = await Permission.storage.request();
    }
    
    if (status.isGranted) {
      final directory = await getExternalStorageDirectory();
      final timestamp = DateTime.now().toString().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
      final file = File('${directory!.path}/final_manual_input_$timestamp.json');
      
      await file.writeAsString(json.encode(_activeAccounts));
      
      _showSuccess("Results saved successfully! (${_activeAccounts.length} active accounts)");
      OpenFile.open(file.path);
    } else {
      _showError("Storage permission denied");
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      )
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      )
    );
  }

  void _showInfo(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Text input
          TextField(
            controller: _textController,
            maxLines: 10,
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Enter usernames (one per line)',
            ),
          ),
          SizedBox(height: 16),
          
          // Start processing button
          ElevatedButton(
            onPressed: _processing ? null : _startProcessing,
            child: Text("Start Processing"),
          ),
          SizedBox(height: 16),
          
          // Progress section
          if (_showProgress) ...[
            LinearProgressIndicator(
              value: _totalCount > 0 ? _processedCount / _totalCount : 0,
            ),
            SizedBox(height: 8),
            Text("Progress: $_processedCount/$_totalCount (${_totalCount > 0 ? (_processedCount * 100 / _totalCount).round() : 0}%)"),
            SizedBox(height: 16),
            
            // Stats
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatCard("Active", _activeCount, Colors.red),
                _buildStatCard("Available", _availableCount, Colors.green),
                _buildStatCard("Error", _errorCount, Colors.orange),
                _buildStatCard("Total", _totalCount, Colors.blue),
              ],
            ),
            SizedBox(height: 16),
            
            // Results list
            Container(
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
              child: ListView.builder(
                reverse: true,
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final item = _results[index];
                  return ResultListItem(item: item);
                },
              ),
            ),
            SizedBox(height: 16),
            
            // Action buttons
            Row(
              children: [
                if (_showCancelButton)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _cancelProcessing,
                      child: Text("Cancel"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    ),
                  ),
                if (_showCancelButton) SizedBox(width: 16),
                if (_showDownloadButton)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _downloadResults,
                      child: Text("Download Results"),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
  
  Widget _buildStatCard(String title, int count, Color color) {
    return Column(
      children: [
        Text(title, style: TextStyle(fontSize: 12)),
        Text("$count", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}

class ConverterTab extends StatefulWidget {
  @override
  _ConverterTabState createState() => _ConverterTabState();
}

class _ConverterTabState extends State<ConverterTab> {
  String? _selectedJsonFileName;
  PlatformFile? _selectedJsonFile;
  bool _converting = false;

  Future<void> _pickJsonFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result != null) {
      setState(() {
        _selectedJsonFile = result.files.first;
        _selectedJsonFileName = _selectedJsonFile!.name;
      });
    }
  }

  Future<void> _convertToExcel() async {
    if (_selectedJsonFile == null) {
      _showError("Please select a JSON file first");
      return;
    }

    setState(() {
      _converting = true;
    });

    try {
      // Read JSON file
      String content = String.fromCharCodes(_selectedJsonFile!.bytes!);
      List<dynamic> jsonData = json.decode(content);
      
      // Create Excel workbook
      final excel = Excel.createExcel();
      final sheet = excel['Instagram Accounts'];
      
      // Add headers
      sheet.appendRow(['Username', 'Password', 'Auth Code', 'Email']);
      
      // Add data rows
      for (var item in jsonData) {
        sheet.appendRow([
          item['username']?.toString() ?? '',
          item['password']?.toString() ?? '',
          item['auth_code']?.toString() ?? '',
          item['email']?.toString() ?? '',
        ]);
      }
      
      // Save Excel file
      final directory = await getExternalStorageDirectory();
      final baseName = _selectedJsonFileName!.substring(0, _selectedJsonFileName!.lastIndexOf('.'));
      final timestamp = DateTime.now().toString().replaceAll(RegExp(r'[^0-9]'), '').substring(0, 14);
      final outputPath = '${directory!.path}/${baseName}_$timestamp.xlsx';
      
      final file = File(outputPath);
      await file.writeAsBytes(excel.encode()!);
      
      setState(() {
        _converting = false;
      });
      
      _showSuccess("Excel file created successfully!");
      OpenFile.open(outputPath);
    } catch (e) {
      setState(() {
        _converting = false;
      });
      _showError("Conversion failed: $e");
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      )
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "Convert JSON results to Excel format",
            style: TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 24),
          
          // File selection
          ElevatedButton.icon(
            onPressed: _converting ? null : _pickJsonFile,
            icon: Icon(_selectedJsonFileName != null ? Icons.check_circle : Icons.attach_file),
            label: Text(_selectedJsonFileName ?? "Select JSON File"),
            style: ElevatedButton.styleFrom(
              backgroundColor: _selectedJsonFileName != null ? Colors.green[50] : null,
              foregroundColor: _selectedJsonFileName != null ? Colors.green[700] : null,
            ),
          ),
          SizedBox(height: 16),
          
          // Convert button
          ElevatedButton(
            onPressed: (_selectedJsonFileName != null && !_converting) ? _convertToExcel : null,
            child: _converting 
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(value: null, color: Colors.white),
                      SizedBox(width: 8),
                      Text("Converting..."),
                    ],
                  )
                : Text("Convert to Excel"),
          ),
        ],
      ),
    );
  }
}

class ResultItem {
  final String status;
  final String message;

  ResultItem(this.status, this.message);
}

class ResultListItem extends StatelessWidget {
  final ResultItem item;

  const ResultListItem({Key? key, required this.item}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color textColor;
    IconData icon;
    Color indicatorColor;

    switch (item.status) {
      case "ACTIVE":
        bgColor = Color(0xFFFECACA);
        textColor = Color(0xFFDC2626);
        icon = Icons.error;
        indicatorColor = Color(0xFFDC2626);
        break;
      case "AVAILABLE":
        bgColor = Color(0xFFD1FAE5);
        textColor = Color(0xFF059669);
        icon = Icons.check_circle;
        indicatorColor = Color(0xFF059669);
        break;
      case "ERROR":
        bgColor = Color(0xFFFEF3C7);
        textColor = Color(0xFFD97706);
        icon = Icons.warning;
        indicatorColor = Color(0xFFD97706);
        break;
      default: // INFO
        bgColor = Color(0xFFF9FAFB);
        textColor = Color(0xFF6B7280);
        icon = Icons.info;
        indicatorColor = Color(0xFF6B7280);
        break;
    }

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
      ),
      padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 40,
            color: indicatorColor,
          ),
          SizedBox(width: 12),
          Icon(icon, color: textColor),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              item.message,
              style: TextStyle(color: textColor),
            ),
          ),
        ],
      ),
    );
  }
}

// Semaphore implementation for limiting concurrent requests
class Semaphore {
  int _maxCount;
  int _currentCount = 0;
  final List<Completer<void>> _waiting = [];

  Semaphore(this._maxCount);

  Future<void> acquire() async {
    if (_currentCount < _maxCount) {
      _currentCount++;
      return;
    }

    final completer = Completer<void>();
    _waiting.add(completer);
    await completer.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _currentCount--;
    }
  }
}
