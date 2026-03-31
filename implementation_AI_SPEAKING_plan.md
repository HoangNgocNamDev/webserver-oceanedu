# Hướng dẫn triển khai: Chấm điểm Speaking bằng AI

> **Dự án gốc tham khảo**: OceanEduSpeaking  
> **Pattern tham khảo**: [openai/openai-realtime-agents](https://github.com/openai/openai-realtime-agents)  
> **Ngày**: 2026-03-31

---

## Mục lục

1. [Tổng quan kiến trúc](#1-tổng-quan-kiến-trúc)
2. [Yêu cầu hệ thống & tài khoản](#2-yêu-cầu-hệ-thống--tài-khoản)
3. [Backend: NestJS API](#3-backend-nestjs-api)
4. [Client: Flutter App](#4-client-flutter-app)
5. [Luồng dữ liệu end-to-end](#5-luồng-dữ-liệu-end-to-end)
6. [Cấu hình môi trường](#6-cấu-hình-môi-trường)
7. [Checklist triển khai](#7-checklist-triển-khai)

---

## 1. Tổng quan kiến trúc

### 1.1 Pattern: Chat-Supervisor từ openai-realtime-agents

Hệ thống sử dụng pattern **Chat-Supervisor** — một Chat Agent tốc độ cao (realtime) tương tác trực tiếp với user, trong khi một Supervisor Agent thông minh hơn (text-based) chịu trách nhiệm phân tích chất lượng ngôn ngữ.

```
┌─────────────────────────────────────────────────────────────┐
│                    KIẾN TRÚC HỆ THỐNG                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  [Mobile App]  ←─ WebRTC ─→  [OpenAI Realtime API]         │
│       │              Data Channel (oai-events)              │
│       │                     │                               │
│       │    event: conversation.item.input_audio_            │
│       │           transcription.completed                   │
│       │                     │                               │
│       └──── HTTP POST ──→  [Backend API]                    │
│                              │                              │
│              ┌───────────────┼──────────────┐               │
│              ▼               ▼              ▼               │
│     [Azure Speech SDK]  [OpenAI GPT]  [OpenAI GPT]         │
│     Pron/Fluency/Prosody  Grammar     Vocabulary            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Hai loại scoring

| Loại | Trigger | Nguồn dữ liệu | Kết quả |
|------|---------|---------------|---------|
| **Pronunciation Assessment** | Sau mỗi utterance của user (có audio file) | Azure Speech SDK + GPT | PronScore, FluencyScore, ProsodyScore, GrammarScore, VocabScore + mistakes |
| **Text Analysis** | Sau mỗi utterance (chỉ cần transcript) | OpenAI GPT | need_improvement, feedback, suggestions, confidence_score |

---

## 2. Yêu cầu hệ thống & tài khoản

### 2.1 Services cần đăng ký

```
✅ OpenAI API Key
   - Sử dụng: gpt-4o-mini-realtime (Chat Agent), gpt-4o-mini (Scoring)
   - URL: https://platform.openai.com/api-keys

✅ Azure Speech Service
   - Sử dụng: Pronunciation Assessment API
   - URL: https://portal.azure.com → Cognitive Services → Speech
   - Cần: AZURE_SPEECH_KEY + AZURE_SPEECH_REGION
```

### 2.2 Tech stack

**Backend:**
- Node.js + NestJS (TypeScript)
- `openai` npm package
- `microsoft-cognitiveservices-speech-sdk` npm package
- `zod` cho structured output validation
- Multer cho file upload

**Mobile Client:**
- Flutter/Dart
- `flutter_webrtc` package
- `dio` package cho HTTP

---

## 3. Backend: NestJS API

### 3.1 Cấu trúc thư mục

```
src/modules/roleplay/
├── dto/
│   ├── tts-request.dto.ts
│   ├── analysis-request.dto.ts          ← Input: { input: string }
│   ├── analysis-response.dto.ts         ← Output: { analysisResult, timestamp }
│   ├── pronunciation-assessment-request.dto.ts
│   └── pronunciation-assessment-response.dto.ts
├── roleplay.controller.ts
├── roleplay.module.ts
└── roleplay.service.ts
```

### 3.2 DTOs

#### `analysis-request.dto.ts`
```typescript
import { ApiProperty } from '@nestjs/swagger';
import { IsString, IsNotEmpty } from 'class-validator';

export class AnalysisRequestDto {
  @ApiProperty({ description: 'Text transcript to analyze', example: 'what name?' })
  @IsString()
  @IsNotEmpty()
  input: string;
}
```

#### `analysis-response.dto.ts` — Schema của `analysisResult` (nested JSON string)
```typescript
export class AnalysisResponseDto {
  // JSON string chứa kết quả phân tích chi tiết
  analysisResult: string;  // parse ra: { need_improvement, feedback, suggestions, confidence_score, original_transcript }
  timestamp: string;
}

// Cấu trúc của analysisResult khi parse:
// {
//   need_improvement: boolean,
//   feedback: string,           // Phản hồi ngắn gọn
//   suggestions: string[],      // Gợi ý cải thiện (mảng rỗng nếu tốt)
//   confidence_score: number,   // 0-100
//   original_transcript: string
// }
```

#### `pronunciation-assessment-request.dto.ts`
```typescript
export class PronunciationAssessmentRequestDto {
  audioBuffer: Buffer;        // Audio file buffer
  transcript: string;         // Expected text (có thể rỗng)
  topic?: string;             // Chủ đề conversation
  responseLanguage?: string;  // Ngôn ngữ phản hồi (vi/en)
}
```

#### `pronunciation-assessment-response.dto.ts`
```typescript
export class AssessmentScoresDto {
  PronScore: number;      // Phát âm (Azure)
  FluencyScore: number;   // Độ trơn tru (Azure)
  ProsodyScore: number;   // Ngữ điệu (Azure)
  GrammarScore: number;   // Ngữ pháp (GPT)
  VocabScore: number;     // Từ vựng (GPT)
}

export class PronunciationAssessmentResponseDto {
  Assessment: AssessmentScoresDto;
  mistakes: {
    pronunciation: PronunciationMistakeDto[];
    grammar: GrammarMistakeDto[];
    vocabulary: VocabularyMistakeDto[];
  };
  recognizedText: string;
  feedback?: string;
}
```

### 3.3 Service: `roleplay.service.ts`

#### Khởi tạo
```typescript
@Injectable()
export class RoleplayService {
  private openai: OpenAI;
  private azureSpeechKey: string;
  private azureSpeechRegion: string;

  constructor(private configService: ConfigService) {
    this.openai = new OpenAI({ apiKey: configService.get('OPENAI_API_KEY') });
    this.azureSpeechKey = configService.get('AZURE_SPEECH_KEY');
    this.azureSpeechRegion = configService.get('AZURE_SPEECH_REGION');
  }
```

#### Method 1: `analyzeText()` — Text-only analysis

```typescript
async analyzeText(input: string): Promise<{ analysisResult: string; timestamp: string }> {
  // Zod schema cho structured output
  const AnalysisSchema = z.object({
    need_improvement: z.boolean(),
    feedback: z.string(),
    suggestions: z.array(z.string()),
    confidence_score: z.number().min(0).max(100),
    original_transcript: z.string(),
  });

  const response = await this.openai.chat.completions.create({
    model: 'gpt-4o-mini',
    messages: [
      {
        role: 'system',
        content: `You are an English speaking coach for children (ages 8-15).
Analyze the student's English text and determine:
- need_improvement: true if there are grammar/vocabulary/clarity issues worth addressing
- feedback: short, encouraging feedback in simple language (max 2 sentences)
- suggestions: list of specific improvement suggestions (empty array if no improvement needed)
- confidence_score: 0-100, how confident/fluent the student's expression seems
- original_transcript: repeat the original text as-is

Be encouraging and supportive. Don't be overly critical.
Ignore filler words (uh, um, etc.) when scoring.`
      },
      { role: 'user', content: input }
    ],
    response_format: zodResponseFormat(AnalysisSchema, 'analysis'),
    temperature: 0.3,
  });

  const result = AnalysisSchema.parse(JSON.parse(response.choices[0].message.content!));
  return {
    analysisResult: JSON.stringify(result),
    timestamp: new Date().toISOString(),
  };
}
```

#### Method 2: `assessGrammarAndVocabulary()` — GPT scoring (private)

```typescript
private async assessGrammarAndVocabulary(recognizedText: string, expectedText?: string) {
  // Zod schema
  const GrammarVocabSchema = z.object({
    grammarScore: z.number().min(0).max(100),
    vocabularyScore: z.number().min(0).max(100),
    grammarMistakes: z.array(z.object({
      issue: z.string(),
      correction: z.string(),
      explanation: z.string(),
    })),
    vocabularyMistakes: z.array(z.object({
      issue: z.string(),
      suggestion: z.string(),
      explanation: z.string(),
    })),
  });

  // Grammar Rubric:
  // 90-100: Perfect, 80-89: Excellent (1-2 errors), 70-79: Good (3-4),
  // 60-69: Fair (5-6), 50-59: Poor (7-8), ...

  const systemPrompt = `...rubric scoring prompt...`;
  const userPrompt = expectedText
    ? `EXPECTED: "${expectedText}"\nSTUDENT SAID: "${recognizedText}"`
    : `STUDENT SAID: "${recognizedText}"`;

  const response = await this.openai.chat.completions.create({
    model: 'gpt-4o-mini',
    messages: [{ role: 'system', content: systemPrompt }, { role: 'user', content: userPrompt }],
    temperature: 0.1,  // Low for consistency
    response_format: zodResponseFormat(GrammarVocabSchema, 'grammar_vocab_assessment'),
  });

  return GrammarVocabSchema.parse(JSON.parse(response.choices[0].message.content!));
}
```

#### Method 3: `assessPronunciation()` — Full assessment với Azure

```typescript
async assessPronunciation(request: PronunciationAssessmentRequestDto) {
  // 1. Azure Speech SDK assessment
  const azureResult = await this.performAzureAssessment(request);

  // 2. GPT Grammar + Vocabulary scoring
  const gptEvaluation = await this.assessGrammarAndVocabulary(
    azureResult.recognizedText,
    request.transcript,
  );

  // 3. Extract pronunciation mistakes từ Azure raw result
  const pronunciationMistakes = this.extractPronunciationMistakes(azureResult.azureResult);

  // 4. Build response
  return {
    Assessment: {
      PronScore: azureResult.azureResult.NBest[0].PronunciationAssessment.PronScore,
      FluencyScore: azureResult.azureResult.NBest[0].PronunciationAssessment.FluencyScore,
      ProsodyScore: azureResult.azureResult.NBest[0].PronunciationAssessment.ProsodyScore,
      GrammarScore: gptEvaluation.grammarScore,
      VocabScore: gptEvaluation.vocabularyScore,
    },
    mistakes: {
      pronunciation: pronunciationMistakes,
      grammar: gptEvaluation.grammarMistakes,
      vocabulary: gptEvaluation.vocabularyMistakes,
    },
    recognizedText: azureResult.recognizedText,
    feedback: this.generateOverallFeedback(...scores),
  };
}
```

#### Method 4: `performAzureAssessment()` — Azure SDK integration (private)

```typescript
private async performAzureAssessment(request: PronunciationAssessmentRequestDto) {
  const speechConfig = sdk.SpeechConfig.fromSubscription(
    this.azureSpeechKey, this.azureSpeechRegion
  );
  speechConfig.speechRecognitionLanguage = 'en-US';

  // Đẩy audio buffer vào PushStream
  const pushStream = sdk.AudioInputStream.createPushStream();
  pushStream.write(request.audioBuffer.buffer);
  pushStream.close();

  const audioConfig = sdk.AudioConfig.fromStreamInput(pushStream);

  // Cấu hình PronunciationAssessment
  const config = new sdk.PronunciationAssessmentConfig(
    request.transcript,
    sdk.PronunciationAssessmentGradingSystem.HundredMark,
    sdk.PronunciationAssessmentGranularity.Phoneme,
    false
  );
  config.enableProsodyAssessment = true;
  if (request.transcript && request.topic) {
    config.enableContentAssessmentWithTopic(request.topic);
  }

  const recognizer = new sdk.SpeechRecognizer(speechConfig, audioConfig);
  config.applyTo(recognizer);

  return new Promise((resolve, reject) => {
    recognizer.recognizeOnceAsync(
      (result) => {
        if (result.reason === sdk.ResultReason.RecognizedSpeech) {
          const jsonResult = result.properties.getProperty(
            sdk.PropertyId.SpeechServiceResponse_JsonResult
          );
          resolve({ recognizedText: result.text, azureResult: JSON.parse(jsonResult) });
        } else {
          reject(new Error(`Recognition failed: ${sdk.ResultReason[result.reason]}`));
        }
        recognizer.close();
      },
      (error) => { recognizer.close(); reject(error); }
    );
  });
}
```

### 3.4 Controller: `roleplay.controller.ts`

```typescript
@ApiTags('roleplay')
@Controller('roleplay')
@UseGuards(AuthGuard)
@ApiBearerAuth('access-token')
export class RoleplayController {

  // ─── 1. Text-to-Speech ─────────────────────────────────────────
  @Post('tts')
  @Header('Content-Type', 'audio/mpeg')
  async generateSpeech(@Body() body: TtsRequestDto, @Res() res: Response) {
    const buffer = await this.roleplayService.generateSpeech(body.input, body.voice);
    res.send(buffer);
  }

  // ─── 2. Translation ────────────────────────────────────────────
  @Post('translate')
  async translateText(@Body() body: TranslationRequestDto) {
    const text = await this.roleplayService.translateText(body.input, body.sourceLanguage, body.targetLanguage);
    return { translatedText: text, timestamp: new Date().toISOString() };
  }

  // ─── 3. Text Analysis (Supervisor) ────────────────────────────
  @Post('analyze-text')
  async analyzeText(@Body() body: AnalysisRequestDto): Promise<AnalysisResponseDto> {
    return this.roleplayService.analyzeText(body.input);
  }

  // ─── 4. Pronunciation Assessment ──────────────────────────────
  @Post('pronunciation-assessment')
  @UseInterceptors(FileInterceptor('audioFile'))
  async assessPronunciation(
    @UploadedFile() file: Express.Multer.File,
    @Body() body: any,
  ): Promise<PronunciationAssessmentResponseDto> {
    return this.roleplayService.assessPronunciation({
      audioBuffer: file.buffer,
      transcript: body.transcript || '',
      topic: body.topic || '',
      responseLanguage: body.responseLanguage || 'en',
    });
  }

  // ─── 5. Suggestions ───────────────────────────────────────────
  @Post('suggestions')
  async generateSuggestions(@Body() body: SuggestionRequestDto) {
    const suggestions = await this.roleplayService.generateSuggestions(body.input, body.numberOfSuggestions);
    return { suggestions, count: suggestions.length, timestamp: new Date().toISOString() };
  }
}
```

---

## 4. Client: Flutter App

### 4.1 Cấu trúc thư mục

```
lib/features/roleplay/
├── data/
│   └── datasources/
│       └── roleplay_utils_remote_datasource.dart  ← HTTP calls đến API
├── models/
│   ├── chat_message.dart           ← ChatMessage, SupervisorAnalysis, Assessment, Mistakes
│   ├── pronunciation_assessment_request.dart
│   └── pronunciation_assessment_response.dart
├── services/
│   ├── chat_service.dart           ← WebRTC + OpenAI Realtime events
│   └── roleplay_utils_service.dart ← Business logic layer
└── widgets/
    └── roleplay_message_bubble.dart ← UI hiển thị kết quả
```

### 4.2 Model: `chat_message.dart`

```dart
class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final bool fromVoice;
  final String? audioFilePath;          // Path audio file đã record
  final SupervisorAnalysis? supervisorAnalysis;  // Kết quả phân tích

  bool get needsImprovement => supervisorAnalysis?.needsImprovement ?? false;

  ChatMessage copyWithSupervisorAnalysis(SupervisorAnalysis analysis) => ...;
}

class SupervisorAnalysis {
  final Assessment assessment;           // Điểm số
  final Mistakes mistakes;               // Lỗi chi tiết
  final String recognizedText;           // Text đã nhận dạng
  final String? feedback;               // Feedback tổng quát
  final bool needsImprovement;         // Có cần cải thiện không
  final DateTime timestamp;
}

class Assessment {
  final double? pronScore;     // Phát âm (Azure)
  final double? fluencyScore;  // Trôi chảy (Azure)
  final double? prosodyScore;  // Ngữ điệu (Azure)
  final double? grammarScore;  // Ngữ pháp (GPT)
  final double? vocabScore;    // Từ vựng (GPT)
}

class Mistakes {
  final List<PronunciationMistakeDetail> pronunciation;
  final List<GrammarMistakeDetail> grammar;
  final List<VocabularyMistakeDetail> vocabulary;
}
```

### 4.3 Remote Datasource: `roleplay_utils_remote_datasource.dart`

```dart
class RoleplayUtilsRemoteDataSource {
  final BaseApi _baseApi;

  // ─── Pronunciation Assessment (multipart/form-data) ────────────
  Future<PronunciationAssessmentResponseDto> assessPronunciation(
    PronunciationAssessmentRequest request
  ) async {
    final formData = FormData.fromMap({
      'audioFile': await MultipartFile.fromFile(
        request.audioFile.path,
        filename: 'audio.${_getFileExtension(request.audioFile.path)}',
      ),
      if (request.transcript?.isNotEmpty == true) 'transcript': request.transcript,
      if (request.topic?.isNotEmpty == true) 'topic': request.topic,
      if (request.responseLanguage?.isNotEmpty == true)
        'responseLanguage': request.responseLanguage,
    });

    final response = await _baseApi.dio.post<Map<String, dynamic>>(
      '/api/roleplay/pronunciation-assessment',
      data: formData,
      options: Options(receiveTimeout: Duration(seconds: 60)),
    );

    return PronunciationAssessmentResponseDto.fromJson(response.data!);
  }

  // ─── Text Analysis (JSON) ──────────────────────────────────────
  Future<AnalysisResponse> analyzeText(String input) async {
    final response = await _baseApi.post(
      '/api/roleplay/analyze-text',
      data: { 'input': input },
    );
    return AnalysisResponse.fromJson(response.data);
  }
}
```

### 4.4 Service chính: `chat_service.dart`

#### Kết nối WebRTC với OpenAI Realtime
```dart
static Future<void> connectToOpenAIRealtimeWebRTC({
  required Function(String) onEvent,
  required Function(MediaStream) onRemoteAudio,
  Function(String)? onTranscript,
  Function(SupervisorAnalysis)? onSupervisorAnalysis,
  // ... các callback khác
}) async {
  // 1. Tạo RTCPeerConnection
  _peerConnection = await createPeerConnection({
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });

  // 2. Lấy microphone stream
  _localStream = await navigator.mediaDevices.getUserMedia({
    'audio': {
      'echoCancellation': true,
      'noiseSuppression': true,
      'sampleRate': 24000,  // OpenAI Realtime yêu cầu 24kHz
      'channelCount': 1,    // Mono
    },
    'video': false,
  });

  // 3. Tạo DataChannel cho events
  _dataChannel = await _peerConnection!.createDataChannel(
    'oai-events',
    RTCDataChannelInit()..ordered = true,
  );

  _dataChannel!.onMessage = (msg) {
    final data = jsonDecode(msg.text);
    _handleRealtimeEvent(data);  // Xử lý events
  };

  // 4. Lấy ephemeral key từ backend và kết nối SDP
  final ephemeralKey = await _fetchEphemeralKey();
  final offer = await _peerConnection!.createOffer({...});
  await _sendSdpToOpenAI(ephemeralKey, offer.sdp!);
}
```

#### Session configuration
```dart
static Map<String, Object?> getOpenAIRequestBody() {
  return {
    "model": "gpt-4o-mini-realtime-preview-2024-12-17",  // Hoặc gpt-realtime-2025-xx
    "modalities": ["audio", "text"],
    "input_audio_format": "pcm16",
    "output_audio_format": "pcm16",
    "input_audio_transcription": {
      "model": "gpt-4o-transcribe",
      "language": "en",
    },
    "instructions": _currentInstructions,  // System prompt
    "voice": "alloy",
    "temperature": 0.7,
    "turn_detection": null,  // Push-to-talk mode
    "tool_choice": "none",
    "tools": [],
  };
}

static void sessionUpdateEvent() {
  _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
    'type': 'session.update',
    'session': getOpenAIRequestBody(),
  })));
}
```

#### Xử lý events quan trọng
```dart
static void _handleRealtimeEvent(Map<String, dynamic> event) {
  switch (event['type']) {

    // ─── Session created: gửi config ───────────────────────────
    case 'session.created':
      sessionUpdateEvent();
      _onSessionCreatedCallback?.call();
      break;

    // ─── AI bắt đầu phản hồi ────────────────────────────────────
    case 'response.created':
      _onAIResponseStartCallback?.call();
      break;

    // ─── Transcript user hoàn tất ────────────────────────────────
    // ⭐ ĐÂY LÀ EVENT QUAN TRỌNG NHẤT để trigger scoring
    case 'conversation.item.input_audio_transcription.completed':
      final transcript = event['transcript'] as String?;
      if (transcript != null) {
        // 1. Thông báo transcript cho UI
        _onTranscriptCallback?.call(transcript);

        // 2. Gọi Pronunciation Assessment (cần audio file)
        final audioFilePath = _currentVoiceMessage?.audioFilePath;
        if (audioFilePath != null && _onSupervisorAnalysisCallback != null) {
          Future.microtask(() =>
            _callPronunciationAssessmentAPI(transcript, audioFilePath)
          );
        }
        
        // ⭐ 3. (Optional) Gọi Text Analysis (chỉ cần transcript)
        // Future.microtask(() => _callAnalyzeTextAPI(transcript));
      }
      break;

    // ─── AI hoàn tất phản hồi audio ────────────────────────────
    case 'response.audio_transcript.done':
      final transcript = event['transcript'] as String?;
      if (transcript != null) {
        _onAudioOutputStartedCallback?.call(transcript);
      }
      break;

    // ─── Audio output dừng ───────────────────────────────────────
    case 'output_audio_buffer.stopped':
      _onAudioOutputStoppedCallback?.call();
      _onTranscriptionCompletedCallback?.call();
      break;
  }
}
```

#### Gọi Pronunciation Assessment API
```dart
static Future<void> _callPronunciationAssessmentAPI(
  String transcript,
  String? audioFilePath,
) async {
  try {
    final audioFile = File(audioFilePath!);
    if (!await audioFile.exists()) return;

    final roleplayUtilsService = GetIt.I<RoleplayUtilsService>();

    // Gọi API (multipart upload)
    final response = await roleplayUtilsService.assessPronunciation(
      audioFile: audioFile,
      transcript: transcript,
      topic: _currentTopic,
      responseLanguage: 'en',
    );

    // Tạo SupervisorAnalysis từ response
    final analysis = SupervisorAnalysis(
      assessment: Assessment(
        pronScore: response.assessment.pronScore,
        fluencyScore: response.assessment.fluencyScore,
        prosodyScore: response.assessment.prosodyScore,
        grammarScore: response.assessment.grammarScore,
        vocabScore: response.assessment.vocabScore,
      ),
      mistakes: Mistakes(
        pronunciation: response.mistakes.pronunciation.map((m) =>
          PronunciationMistakeDetail(...)
        ).toList(),
        grammar: response.mistakes.grammar.map((m) =>
          GrammarMistakeDetail(...)
        ).toList(),
        vocabulary: response.mistakes.vocabulary.map((m) =>
          VocabularyMistakeDetail(...)
        ).toList(),
      ),
      recognizedText: response.recognizedText,
      feedback: response.feedback,
      needsImprovement: response.mistakes.pronunciation.isNotEmpty ||
                        response.mistakes.grammar.isNotEmpty ||
                        response.mistakes.vocabulary.isNotEmpty,
      timestamp: DateTime.now(),
    );

    // Callback về UI
    _onSupervisorAnalysisCallback?.call(analysis);

    // Xóa audio file sau khi xử lý
    await Future.delayed(Duration(seconds: 2));
    await audioFile.delete();

  } catch (e) {
    print('❌ Error in pronunciation assessment: $e');
    // Fallback: trả về analysis rỗng, không crash app
    _onSupervisorAnalysisCallback?.call(SupervisorAnalysis(
      assessment: Assessment(),
      mistakes: Mistakes(pronunciation: [], grammar: [], vocabulary: []),
      recognizedText: transcript,
      feedback: null,
      needsImprovement: false,
      timestamp: DateTime.now(),
    ));
  }
}
```

#### Push-to-talk controls
```dart
// Bắt đầu ghi âm (user nhấn nút mic)
static void startAudioInput() {
  _localAudioTrack?.enabled = true;
}

// Dừng ghi âm + trigger AI response (user nhả nút mic)
static void stopAudioInput() {
  // Commit audio buffer
  _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
    'type': 'input_audio_buffer.commit'
  })));

  // Yêu cầu AI generate response
  _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
    'type': 'response.create',
    'response': {
      'modalities': ['text', 'audio'],
      'instructions': _currentInstructions,
    },
  })));

  _localAudioTrack?.enabled = false;
}
```

### 4.5 Ephemeral Key từ Backend

Để bảo mật OPENAI_API_KEY, client không gọi trực tiếp OpenAI mà lấy ephemeral key từ backend:

**Backend endpoint:**
```typescript
@Post('realtime/session')
async createRealtimeSession(@Body() body: any) {
  const session = await this.openai.beta.realtime.sessions.create({
    model: 'gpt-4o-mini-realtime-preview-2024-12-17',
    ...body,  // { instructions, voice, tools, ... }
  });
  return { clientSecret: session.client_secret };
}
```

**Flutter:**
```dart
static Future<String?> fetchEphemeralKey() async {
  final response = await _baseApi.post('/api/realtime/session', data: getOpenAIRequestBody());
  return response.data['clientSecret']['value'] as String?;
}
```

---

## 5. Luồng dữ liệu end-to-end

```
1. User mở màn hình roleplay
   └─→ App gọi GET /api/realtime/session → nhận ephemeral key

2. App thiết lập WebRTC với OpenAI Realtime
   └─→ SDP offer/answer exchange
   └─→ DataChannel 'oai-events' established
   └─→ Gửi session.update với config + instructions

3. User nhấn nút mic → startAudioInput()
   └─→ _localAudioTrack.enabled = true
   └─→ Audio stream → OpenAI Realtime API (qua WebRTC)
   └─→ Bắt đầu record audio file (voice_TIMESTAMP.m4a)

4. User nhả nút mic → stopAudioInput()
   └─→ input_audio_buffer.commit
   └─→ response.create (AI sẽ generate)
   └─→ _localAudioTrack.enabled = false

5. OpenAI Realtime → App events:
   ├─ conversation.item.input_audio_transcription.completed
   │   └─→ Nhận transcript của user
   │   └─→ [ASYNC] POST /api/roleplay/pronunciation-assessment
   │             (upload audio file + transcript)
   │
   ├─ response.audio_transcript.done
   │   └─→ Nhận transcript của AI response
   │
   └─ output_audio_buffer.stopped
       └─→ AI xong việc nói

6. Backend nhận assessment request
   ├─ Azure Speech SDK → PronScore, FluencyScore, ProsodyScore + mistakes
   └─ OpenAI GPT → GrammarScore, VocabScore + grammar/vocab mistakes
   └─→ Trả về PronunciationAssessmentResponseDto

7. App nhận response → tạo SupervisorAnalysis
   └─→ Callback onSupervisorAnalysis → UI cập nhật
   └─→ Hiển thị scores + mistakes trên message bubble
   └─→ Nếu needsImprovement = true → hiển thị button "Phân tích"
```

---

## 6. Cấu hình môi trường

### 6.1 Backend `.env`

```bash
# OpenAI
OPENAI_API_KEY=sk-...

# Azure Speech
AZURE_SPEECH_KEY=your_azure_speech_key
AZURE_SPEECH_REGION=southeastasia  # hoặc region gần nhất

# App config
PORT=3000
NODE_ENV=development
```

### 6.2 NestJS packages cần cài

```bash
npm install openai microsoft-cognitiveservices-speech-sdk zod @nestjs/platform-express multer
npm install -D @types/multer
```

### 6.3 Flutter `pubspec.yaml` packages

```yaml
dependencies:
  flutter_webrtc: ^0.9.0
  dio: ^5.0.0
  get_it: ^7.0.0
  permission_handler: ^11.0.0
  path_provider: ^2.0.0
  record: ^5.0.0  # Để record audio file
```

### 6.4 Flutter permissions

**Android** (`AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
```

**iOS** (`Info.plist`):
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Cần microphone để học nói tiếng Anh</string>
```

---

## 7. Checklist triển khai

### Backend (NestJS)

- [ ] Cài packages: `openai`, `microsoft-cognitiveservices-speech-sdk`, `zod`, `multer`
- [ ] Thêm env vars: `OPENAI_API_KEY`, `AZURE_SPEECH_KEY`, `AZURE_SPEECH_REGION`
- [ ] Tạo DTOs: request/response cho `analyze-text` và `pronunciation-assessment`
- [ ] Implement `RoleplayService.analyzeText()` với GPT structured output
- [ ] Implement `RoleplayService.assessGrammarAndVocabulary()` với Zod schema
- [ ] Implement `RoleplayService.performAzureAssessment()` với Azure Speech SDK
- [ ] Implement `RoleplayService.assessPronunciation()` kết hợp Azure + GPT
- [ ] Thêm endpoints vào Controller: `POST /roleplay/analyze-text`, `POST /roleplay/pronunciation-assessment`
- [ ] Thêm endpoint: `POST /realtime/session` để tạo ephemeral key
- [ ] Cấu hình Multer cho upload audio file
- [ ] Thêm Auth Guard bảo vệ endpoints
- [ ] Test với Postman/Swagger

### Flutter App

- [ ] Thêm packages vào `pubspec.yaml`
- [ ] Thêm Android/iOS permissions
- [ ] Tạo models: `ChatMessage`, `SupervisorAnalysis`, `Assessment`, `Mistakes`
- [ ] Tạo `PronunciationAssessmentRequest` và `Response` models
- [ ] Implement `RoleplayUtilsRemoteDataSource.assessPronunciation()` (multipart)
- [ ] Implement `RoleplayUtilsRemoteDataSource.analyzeText()` (JSON)
- [ ] Implement `ChatService.connectToOpenAIRealtimeWebRTC()` với WebRTC
- [ ] Implement `ChatService._handleRealtimeEvent()` đặc biệt xử lý `input_audio_transcription.completed`
- [ ] Implement `ChatService._callPronunciationAssessmentAPI()` 
- [ ] Implement audio recording song song với WebRTC (để có file upload)
- [ ] Implement `startAudioInput()` / `stopAudioInput()` (push-to-talk)
- [ ] Implement ephemeral key fetching từ backend
- [ ] Cập nhật UI để hiển thị `SupervisorAnalysis` kết quả
- [ ] Xử lý cleanup audio files sau khi upload xong

---

## Phụ lục: Scoring Rubrics

### Grammar Score (GPT sử dụng)

| Score | Mô tả | Số lỗi |
|-------|-------|--------|
| 90-100 | Perfect | 0 |
| 80-89 | Excellent | 1-2 |
| 70-79 | Good | 3-4 |
| 60-69 | Fair | 5-6 |
| 50-59 | Poor | 7-8 |
| 40-49 | Very poor | 9-10 |
| <40 | Severe | 11+ |

### Vocabulary Score (GPT sử dụng)

| Score | Mô tả |
|-------|-------|
| 90-100 | Sophisticated, precise, varied |
| 80-89 | Advanced, appropriate, good variety |
| 70-79 | Good, mostly appropriate |
| 60-69 | Adequate, basic, limited variety |
| <60 | Limited, repetitive, inappropriate |

> **Lưu ý**: GPT dùng `temperature: 0.1` để scoring nhất quán. Bỏ qua filler words (uh, um) và lỗi dấu câu.

### Azure Pronunciation Assessment

Azure SDK trả về tự động qua `PronunciationAssessmentConfig`:
- `PronScore`: Tổng điểm phát âm
- `FluencyScore`: Độ trơn tru (ngừng nghỉ tự nhiên không)
- `ProsodyScore`: Ngữ điệu (stress, rhythm)
- `Words[].PronunciationAssessment.ErrorType`: `None | Mispronunciation | Omission | Insertion`
