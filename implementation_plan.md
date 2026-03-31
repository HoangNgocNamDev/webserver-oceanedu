# Triển khai AI Speaking Assessment cho OceanEdu

> **Tham khảo**: [implementation_AI_SPEAKING_plan.md](file:///c:/Users/hoang/Desktop/OceanEdu/implementation_AI_SPEAKING_plan.md) (dự án OceanEduSpeaking)
> **Pattern**: [openai/openai-realtime-agents](https://github.com/openai/openai-realtime-agents) — Chat-Supervisor
> **Route triển khai**: `/exams/[roomId]/take` (màn hình học sinh làm bài Speaking)

---

## 1. Phân tích hiện trạng dự án

### 1.1 Kiến trúc hiện tại

| Thành phần | Mô tả |
|---|---|
| **oe-exam-api** | NestJS backend, đã có OpenAI + Azure Speech keys trong `.env` |
| **oe-exam-fe** | Next.js frontend, đã có routing `/exams/[roomId]/take` |
| **Speaking flow hiện tại** | Học sinh ghi âm → upload audio lên S3 → lưu audioKey làm answer → chấm **thủ công** bởi giáo viên |
| **Existing hooks** | `useSpeakingRecorder` (record + upload), `useSpeakingNavigation` (navigation giữa questions) |
| **Existing TTS** | `TtsService` dùng OpenAI via OpenRouter, pattern tốt để tham khảo |

### 1.2 Gap Analysis

| Dự án tham khảo (OceanEduSpeaking) | OceanEdu hiện tại | Cần triển khai |
|---|---|---|
| WebRTC realtime conversation với AI | Chỉ ghi âm + upload S3 | **Phase 2** (tương lai) |
| Azure Pronunciation Assessment | Có Azure keys, chưa dùng | ✅ **Phase 1** |
| GPT Grammar/Vocabulary scoring | Có OpenAI key, chưa dùng cho speaking | ✅ **Phase 1** |
| SupervisorAnalysis UI | Chỉ có SpeakingRecordingPreview (playback) | ✅ **Phase 1** |
| Ephemeral key endpoint | Chưa có | **Phase 2** |
| Auto-grading speaking questions | Manual grading (`{ isCorrect: null, score: null }`) | ✅ **Phase 1** |

---

## User Review Required

> [!IMPORTANT]
> **Quyết định kiến trúc quan trọng**: Dự án tham khảo dùng WebRTC cho hội thoại realtime với AI. Tuy nhiên, OceanEdu hiện tại là luồng **ghi âm → upload → chấm** (không có hội thoại). 
>
> Đề xuất triển khai **2 phase**:
> - **Phase 1 (ưu tiên)**: AI chấm điểm audio đã ghi (**không thay đổi flow hiện tại**). Sau khi học sinh ghi âm xong, gọi API chấm điểm ở background.
> - **Phase 2 (tương lai)**: Thêm mode hội thoại realtime với AI cho các question type phù hợp (SPONTANEOUS_QA, INFO_EXCHANGE).
>
> Bạn đồng ý approach này không?

> [!WARNING]
> **Azure Speech SDK trên browser**: Package `microsoft-cognitiveservices-speech-sdk` cho Node.js chỉ chạy ở backend. Audio phải được gửi từ client lên backend xử lý. Điều này **phù hợp** với flow hiện tại (audio đã upload S3).

> [!IMPORTANT]
> **Chi phí API**: Mỗi lần chấm điểm speaking sẽ tốn:
> - Azure Speech: ~$1/1000 phút audio
> - OpenAI GPT-4o-mini: ~$0.15/1M input tokens
>
> Cần xác nhận budget trước khi triển khai.

---

## 2. Proposed Changes

### Tổng quan kiến trúc

```
┌─────────────────────────────────────────────────────────────┐
│                    LUỒNG CHẤM ĐIỂM AI                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  [Student Browser]                                          │
│       │ 1. Ghi âm (existing useSpeakingRecorder)           │
│       │ 2. Upload S3 (existing audio-answer endpoint)       │
│       │ 3. Nhận audioKey                                    │
│       │                                                     │
│       │ 4. POST /speaking-assessment/assess                 │
│       │    { audioKey, transcript?, topic? }                │
│       ▼                                                     │
│  [oe-exam-api]                                              │
│       │                                                     │
│       ├── Download audio từ S3                              │
│       │                                                     │
│       ├──→ [Azure Speech SDK]                               │
│       │     └── PronScore, FluencyScore, ProsodyScore       │
│       │         + word-level pronunciation mistakes         │
│       │                                                     │
│       ├──→ [OpenAI GPT-4o-mini]                            │
│       │     └── GrammarScore, VocabScore                   │
│       │         + grammar/vocabulary mistakes               │
│       │                                                     │
│       └── Trả về SpeakingAssessmentResult                  │
│                                                             │
│  [Student Browser]                                          │
│       └── Hiển thị scores + mistakes inline                │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

### Component 1: Backend — Speaking Assessment Module

#### [NEW] [speaking-assessment.module.ts](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-api/src/modules/shared/speaking-assessment/speaking-assessment.module.ts)

NestJS module đăng ký `SpeakingAssessmentService` và `SpeakingAssessmentController`.

```
src/modules/shared/speaking-assessment/
├── speaking-assessment.module.ts
├── controllers/
│   └── speaking-assessment.controller.ts
├── services/
│   └── speaking-assessment.service.ts
└── dto/
    ├── assess-pronunciation.dto.ts    ← Request: { audioKey, transcript?, topic? }
    ├── assess-text.dto.ts             ← Request: { input }
    └── assessment-response.dto.ts     ← Response: { Assessment, mistakes, recognizedText, feedback }
```

---

#### [NEW] [speaking-assessment.service.ts](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-api/src/modules/shared/speaking-assessment/services/speaking-assessment.service.ts)

Service chính với 4 methods tương ứng với reference:

| Method | Mô tả | Input | Output |
|---|---|---|---|
| `assessPronunciation()` | Full assessment (Azure + GPT) | `audioKey`, `transcript?`, `topic?` | `AssessmentResult` |
| `performAzureAssessment()` | Azure Speech SDK recognition | audio Buffer | `PronScore`, `FluencyScore`, `ProsodyScore` + word mistakes |
| `assessGrammarAndVocabulary()` | GPT structured output | recognized text | `GrammarScore`, `VocabScore` + mistakes |
| `analyzeText()` | Text-only analysis (lighter) | text string | `need_improvement`, `feedback`, `suggestions` |

**Khác biệt với reference**: Thay vì nhận audio file upload trực tiếp, service sẽ **download audio từ S3** bằng `StorageService` (đã có sẵn). Điều này tận dụng flow upload hiện tại.

**Dependencies cần cài thêm**:
```bash
npm install microsoft-cognitiveservices-speech-sdk zod
```

> [!NOTE]
> Package `openai` đã có sẵn (v6.33.0). Package `zod` cần cài mới cho structured output validation.

---

#### [NEW] [speaking-assessment.controller.ts](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-api/src/modules/shared/speaking-assessment/controllers/speaking-assessment.controller.ts)

```typescript
@ApiTags('Speaking Assessment')
@Controller('speaking-assessment')
@UseGuards(AuthGuard, RolesGuard)
@Roles(UserRoles.STUDENT)

// Endpoints:
POST /speaking-assessment/assess       ← Full pronunciation assessment (JSON body, not multipart)
POST /speaking-assessment/analyze-text ← Text-only analysis (lighter endpoint)
```

**Khác biệt với reference**: Reference dùng `multipart/form-data` upload audio. OceanEdu đã có audio trên S3 qua `audioKey`, nên endpoint nhận JSON body `{ audioKey, transcript?, topic? }` thay vì file upload. Đơn giản hơn và tránh duplicate upload.

---

#### [MODIFY] [app.module.ts](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-api/src/app.module.ts)

Import `SpeakingAssessmentModule` vào `AppModule`.

---

#### [MODIFY] [grading.service.ts](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-api/src/modules/student/attempts/services/grading.service.ts)

Thêm integration với `SpeakingAssessmentService` để auto-grade speaking questions thay vì trả `{ isCorrect: null, score: null }`. 

Khi submit attempt:
1. Tìm speaking questions có audio answer
2. Gọi `SpeakingAssessmentService.assessPronunciation()` cho mỗi câu
3. Tính điểm dựa trên weighted average: `pronunciation * 0.3 + fluency * 0.2 + prosody * 0.1 + grammar * 0.2 + vocab * 0.2`
4. Lưu score vào `AttemptAnswer`

> [!IMPORTANT]
> **Auto-grading vs On-demand**: Có 2 cách tiếp cận:
> - **Option A**: Chấm ngay khi upload audio (responsive hơn, student thấy score ngay)
> - **Option B**: Chấm khi submit attempt (đơn giản hơn, nhưng student phải đợi)
>
> Đề xuất **Option A** — chấm ngay sau khi upload, hiển thị score cho student. Khi submit thì dùng score đã cache.

---

### Component 2: Frontend — Assessment Hook & UI

#### [NEW] [useSpeakingAssessment.ts](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-fe/app/(exam-fullscreen)/student/exams/[roomId]/take/hooks/useSpeakingAssessment.ts)

Custom hook gọi backend API sau khi recording upload xong:

```typescript
interface UseSpeakingAssessmentReturn {
  // Assessment result
  assessment: AssessmentResult | null;
  // Loading state
  isAssessing: boolean;
  // Error
  assessmentError: string | null;
  // Trigger assessment manually (auto-triggered on upload complete)
  triggerAssessment: (audioKey: string, transcript?: string) => Promise<void>;
}
```

**Kết nối với `useSpeakingRecorder`**: Khi `recorder.status === 'uploaded'` và `recorder.uploadedKey` có giá trị, tự động gọi `triggerAssessment(uploadedKey)`.

---

#### [NEW] [SpeakingAssessmentPanel.tsx](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-fe/app/(exam-fullscreen)/student/exams/[roomId]/take/components/speaking/SpeakingAssessmentPanel.tsx)

Component hiển thị kết quả chấm điểm theo style của bài thi (wooden theme):

```
┌─────────────────────────────────────┐
│  📊 Kết quả đánh giá               │
│                                     │
│  🎤 Phát âm:     85/100  ████████░ │
│  🗣️ Lưu loát:    78/100  ███████░░ │
│  🎵 Ngữ điệu:    72/100  ██████░░░ │
│  📝 Ngữ pháp:    90/100  █████████ │
│  📚 Từ vựng:     88/100  ████████░ │
│                                     │
│  ⚠️ Cần cải thiện:                  │
│  • "wat" → "what" (phát âm)        │
│  • Missing article "the"           │
│                                     │
│  💡 Feedback: Great job! Try to...  │
└─────────────────────────────────────┘
```

---

#### [NEW] [speaking-assessment.api.ts](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-fe/lib/api/student/speaking-assessment.api.ts)

API client mới cho speaking assessment endpoints:

```typescript
export const speakingAssessmentApi = {
  assess: async (audioKey: string, transcript?: string, topic?: string) => ...,
  analyzeText: async (input: string) => ...,
};
```

---

#### [NEW] [speaking-assessment.types.ts](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-fe/app/(exam-fullscreen)/student/exams/[roomId]/take/types/speaking-assessment.types.ts)

Types cho assessment result, tương ứng với backend DTOs.

---

#### [MODIFY] Existing Speaking Renderers

Tích hợp `useSpeakingAssessment` và `SpeakingAssessmentPanel` vào các speaking renderers hiện có. Thay đổi xảy ra trong các file sau:

- [SpeakingRecordingPreview.tsx](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-fe/app/(exam-fullscreen)/student/exams/[roomId]/take/components/speaking/SpeakingRecordingPreview.tsx) — Thêm assessment results bên dưới audio preview
- [SpeakingListenAndSpeakAnswerRenderer.tsx](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-fe/app/(exam-fullscreen)/student/exams/[roomId]/take/components/speaking/renderers/SpeakingListenAndSpeakAnswerRenderer.tsx) — Integrate hook
- Tương tự cho các renderer khác: `SpeakingDescribeImageRenderer`, `SpeakingQuestionListRenderer`, `SpeakingSpontaneousQARenderer`, `SpeakingReadDisplayedContentRenderer`

---

### Component 3: Environment & Dependencies

#### [MODIFY] [.env](file:///c:/Users/hoang/Desktop/OceanEdu/oe-exam-api/.env)

Đã có sẵn:
```
OPENAI_API_KEY=sk-or-v1-...     ← ✅ (via OpenRouter)
AZURE_SPEECH_KEY=1GnJgznx...    ← ✅
AZURE_SPEECH_REGION=southeastasia ← ✅
```

> [!WARNING]
> **OpenAI API Key via OpenRouter**: Key hiện tại dùng OpenRouter (`sk-or-v1-...`). Cần xác nhận OpenRouter hỗ trợ structured output (`response_format: zodResponseFormat`). Nếu không, cần thêm OpenAI direct API key riêng cho speaking assessment.

Cần thêm (optional):
```
# Speaking Assessment Config
SPEAKING_ASSESSMENT_ENABLED=true
SPEAKING_ASSESSMENT_MODEL=gpt-4o-mini
```

---

## 3. Open Questions

> [!IMPORTANT]
> 1. **OpenRouter vs OpenAI Direct**: Key hiện tại qua OpenRouter. Structured output (Zod schema) có được OpenRouter hỗ trợ không? Nếu không cần OpenAI direct key riêng.

> [!IMPORTANT]
> 2. **Chấm ngay vs Chấm khi submit**: Đề xuất chấm ngay sau khi ghi âm (Option A). Bạn muốn approach nào?

> [!IMPORTANT]
> 3. **Phase 2 - WebRTC Realtime**: Có muốn triển khai mode hội thoại AI realtime (như reference) cho SPONTANEOUS_QA / INFO_EXCHANGE không? Hay chỉ cần chấm audio đã ghi?

> [!IMPORTANT]
> 4. **Question types nào cần AI scoring?** Đề xuất áp dụng cho tất cả speaking question types có audio recording:
>    - `LISTEN_AND_SPEAK_ANSWER`
>    - `LISTEN_AND_SPEAK_COMPARE_IMAGES`
>    - `LISTEN_AND_SPEAK_WITH_STORY_IMAGES`
>    - `LISTEN_AND_SPEAK_ODD_ONE_OUT`
>    - `LISTEN_AND_SPEAK_QUESTION_LIST`
>    - `LISTEN_AND_SPEAK_INFO_EXCHANGE`
>    - `SPEAKING_DESCRIBE_IMAGE`
>    - `READ_DISPLAYED_CONTENT`
>    - `SPONTANEOUS_QA`

---

## 4. Verification Plan

### Automated Tests

```bash
# Backend unit tests
cd oe-exam-api
npm test -- --testPathPattern=speaking-assessment

# Test Azure SDK integration
# (cần audio file thực để test)

# Test GPT structured output
# (cần verify Zod schema parsing)
```

### Manual Verification

1. **Backend API**: Test qua Swagger UI
   - Upload audio → gọi `/speaking-assessment/assess` → verify response format
   - Gọi `/speaking-assessment/analyze-text` → verify structured output

2. **Frontend Integration**: Tại route `/exams/[roomId]/take?mock=speaking`
   - Ghi âm → upload → verify assessment panel hiển thị
   - Verify scores + mistakes display
   - Verify loading state khi đang chấm

3. **End-to-end**: 
   - Tạo bài thi Speaking thực
   - Học sinh ghi âm trả lời
   - Verify auto-scoring sau recording
   - Submit bài → verify scores lưu vào attempt

---

## 5. Phân chia Phases

### Phase 1: Backend Foundation (ưu tiên)
- [ ] Cài packages: `microsoft-cognitiveservices-speech-sdk`, `zod`
- [ ] Tạo `SpeakingAssessmentModule` + Service + Controller
- [ ] Implement `performAzureAssessment()` 
- [ ] Implement `assessGrammarAndVocabulary()` với Zod schema
- [ ] Implement `assessPronunciation()` kết hợp cả hai
- [ ] Implement `analyzeText()` (lighter endpoint)
- [ ] Register module trong `AppModule`
- [ ] Test qua Swagger

### Phase 2: Frontend Integration
- [ ] Tạo types + API client cho speaking assessment
- [ ] Tạo `useSpeakingAssessment` hook
- [ ] Tạo `SpeakingAssessmentPanel` component
- [ ] Integrate vào `SpeakingRecordingPreview`
- [ ] Test với mock mode

### Phase 3: Auto-grading Integration
- [ ] Modify `GradingService` để auto-grade speaking questions
- [ ] Thêm weighted scoring formula
- [ ] Test submit flow

### Phase 4: WebRTC Realtime (tương lai, nếu cần)
- [ ] Ephemeral key endpoint
- [ ] WebRTC setup cho browser
- [ ] Realtime conversation mode cho SPONTANEOUS_QA
