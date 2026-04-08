# AI Speaking Prompt Testing UI Implementation Plan

Mục tiêu: Tạo một trang giao diện giúp giáo viên (và admin) có thể kiểm thử trực tiếp System Prompt và Admin Prompt (Expected answers/Context) cho module chấm điểm Speaking tự động bằng AI.

## Đánh giá yêu cầu và Hệ thống hiện tại
Hệ thống API OceanEdu hiện đang có endpoint kiểm thử LLM là `POST /api/v1/speaking-assessment/test-llm`. Tuy nhiên, endpoint này hiện tại **chưa hỗ trợ nhận cấu hình custom System Prompt** từ bên ngoài, mà đang dùng trực tiếp constant `SYSTEM_SPEAKING_ASSESSMENT_PROMPT` và `SYSTEM_READ_ALOUD_FEEDBACK_PROMPT`.

Do đó, để đáp ứng yêu cầu "Dễ dàng cho giáo viên thử nghiệm prompt", chúng ta cần chỉnh sửa nhẹ ở cả phía Backend (API) và xây dựng mới ở phía Frontend.

## Proposed Changes

### 1. OceanEdu API (Backend)

Cập nhật Controller và Service của `SpeakingAssessment` để cho phép truyền các thông số prompt linh hoạt phục vụ việc test.

#### [MODIFY] `oe-exam-api/src/modules/shared/speaking-assessment/dto/test-assessment.dto.ts`
- Thêm thuộc tính `systemPrompt?` (mô tả custom system intruction nếu ghi đè).
- Thêm thuộc tính `questionType` (những trường hợp: `READ_DISPLAYED_CONTENT`, `SPEAKING_DESCRIBE_IMAGE`, `SPONTANEOUS_QA`).
- Cập nhật `expectedAnswers` linh hoạt hơn hoặc thêm `referenceText` dùng cho test trực tiếp Read Aloud.

#### [MODIFY] `oe-exam-api/src/modules/shared/speaking-assessment/services/llm-assessment.service.ts`
- Cập nhật hàm test đánh giá LLM để nhận thêm tham số `systemPrompt` tùy biến. Nếu người dùng truyền lên `systemPrompt`, sử dụng nó thay thế cho biến constant mặc định.
- Tùy chỉnh việc gọi prompt giữa `READ_DISPLAYED_CONTENT` (chú trọng Reference Text) và `SPONTANEOUS_QA` / `SPEAKING_DESCRIBE_IMAGE` (chú trọng Expected Answers).

#### [MODIFY] `oe-exam-api/src/modules/shared/speaking-assessment/controllers/speaking-assessment.controller.ts`
- Cập nhật `testLlmAssessment` để map các fields mới từ DTO sang Service.

---

### 2. OceanEdu Frontend (UI)

Tạo một trang UI dùng chung cho Admin và Teacher (VD: `/teacher/ai-speaking-prompt-tester`) với giao diện Dashboard hiện đại và dễ dùng, cho phép chia đôi màn hình (Split View): Bên trái là Form nhập thông tin, bên phải là Kết quả chấm điểm (JSON + Preview trực quan).

#### [NEW] `oe-exam-fe/app/teacher/ai-speaking-prompt-tester/page.tsx`
- Layout trang Dashboard với tiêu đề "AI Speaking Prompt Testing".

#### [NEW] `oe-exam-fe/app/teacher/ai-speaking-prompt-tester/_components/PromptTesterForm.tsx` (và các component phụ)
- **Select box**: Chọn Question Type (Hỗ trợ: `READ_DISPLAYED_CONTENT`, `SPEAKING_DESCRIBE_IMAGE`, `SPONTANEOUS_QA`).
- **Textarea 1: System Prompt**: Mặc định sẽ fetch/điền tự động prompt gốc của hệ thống, nhưng giáo viên có thể chỉnh sửa tự do.
- **Textarea 2: Admin Prompt (Expected Answers / Text to Read)**: Text guideline/expectation cho model.
- **Textarea 3: Student Recognized Text**: Giả lập việc học sinh nói và được chuyển thành text.
- **Button "Run Assessment"**: Gửi payload lên API `/api/v1/speaking-assessment/test-llm`.

#### [NEW] `oe-exam-fe/app/teacher/ai-speaking-prompt-tester/_components/PromptTesterResult.tsx`
- **Result Panel**: Hiển thị điểm `contentScore`, `grammarScore` theo dạng thanh Progress Bar.
- **Feedback box**: Trích xuất feedback của AI.
- Dạng thô (Raw JSON Viewer) để giáo viên xem output chuẩn từ LLM.

## Open Questions

> [!IMPORTANT]
> Câu hỏi dành cho bạn (Người review):
> 
> 1. Hiện tại backend chỉ cho phép test ở Endpoint `/api/v1/speaking-assessment/test-llm` sử dụng `gpt-4o-mini`. Bạn muốn trang UI này gọi lên test trực tiếp text-to-text hay bạn còn muốn test cả quá trình upload audio thu âm thực tế? (Trong plan này mình đang tập trung vào text-to-text cho LLM prompt).
> 2. Khúc "Admin Prompt" ở đây bạn muốn hiểu là các **Expected Keywords (Đáp án mong đợi)** cho câu hỏi (VD: dog, cat, play), hay là một đoạn hướng dẫn dài (Guideline) riêng của giáo viên?
> 3. Trang này đặt ở route `/teacher/ai-speaking-prompt-tester` và `/admin/...` là hợp lý chưa?

## Verification Plan
1. Khởi động backend và frontend.
2. Truy cập vào trang UI tester, copy thử một đoạn giả định.
3. Thay đổi System prompt theo hướng khắc nghiệt hơn để xem điểm số Content/Grammar có bị sụt giảm không.
4. Kiểm tra xem format JSON trả về có đúng format hay bị Error parsing.
