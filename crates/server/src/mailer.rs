use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use lettre::message::{Mailbox, MultiPart, SinglePart, header::ContentType};
use lettre::transport::smtp::authentication::Credentials;
use lettre::transport::smtp::client::{Tls, TlsParameters};
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};

use crate::settings::{SmtpSecurity, SmtpSettings};

#[derive(Debug, Clone)]
pub struct OutgoingEmail {
    pub to: String,
    pub subject: String,
    pub text_body: String,
    pub html_body: String,
}

#[async_trait]
pub trait EmailSender: Send + Sync {
    async fn send(&self, smtp: &SmtpSettings, email: &OutgoingEmail) -> anyhow::Result<()>;
}

/// Production SMTP sender backed by `lettre` + `tokio1-rustls-tls`.
pub struct SmtpEmailSender;

#[async_trait]
impl EmailSender for SmtpEmailSender {
    async fn send(&self, smtp: &SmtpSettings, email: &OutgoingEmail) -> anyhow::Result<()> {
        smtp.validate()?;

        let from_addr = smtp
            .from_address
            .trim()
            .parse()
            .map_err(|e| anyhow::anyhow!("发件人邮箱地址无效: {e}"))?;
        let from_name = smtp.from_name.trim();
        let from_mailbox = Mailbox::new(
            (!from_name.is_empty()).then(|| from_name.to_string()),
            from_addr,
        );

        let to_addr = email
            .to
            .trim()
            .parse()
            .map_err(|e| anyhow::anyhow!("收件人邮箱地址无效: {e}"))?;
        let to_mailbox = Mailbox::new(None, to_addr);

        let message = Message::builder()
            .from(from_mailbox)
            .to(to_mailbox)
            .subject(&email.subject)
            .multipart(
                MultiPart::alternative()
                    .singlepart(
                        SinglePart::builder()
                            .header(ContentType::TEXT_PLAIN)
                            .body(email.text_body.clone()),
                    )
                    .singlepart(
                        SinglePart::builder()
                            .header(ContentType::TEXT_HTML)
                            .body(email.html_body.clone()),
                    ),
            )
            .map_err(|e| anyhow::anyhow!("构建邮件内容失败: {e}"))?;

        let host = smtp.host.trim();
        let mut builder = match smtp.security {
            SmtpSecurity::StartTls => {
                let tls = TlsParameters::new(host.to_string())
                    .map_err(|e| anyhow::anyhow!("初始化 STARTTLS 失败: {e}"))?;
                AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(host)
                    .port(smtp.port)
                    .tls(Tls::Required(tls))
            }
            SmtpSecurity::Tls => {
                let tls = TlsParameters::new(host.to_string())
                    .map_err(|e| anyhow::anyhow!("初始化 SMTPS TLS 失败: {e}"))?;
                AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(host)
                    .port(smtp.port)
                    .tls(Tls::Wrapper(tls))
            }
            SmtpSecurity::None => AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(host)
                .port(smtp.port)
                .tls(Tls::None),
        }
        .timeout(Some(Duration::from_secs(15)));

        if !smtp.username.trim().is_empty() || !smtp.password.is_empty() {
            builder = builder.credentials(Credentials::new(
                smtp.username.trim().to_string(),
                smtp.password.clone(),
            ));
        }

        let mailer = builder.build();
        mailer
            .send(message)
            .await
            .map_err(|e| anyhow::anyhow!("SMTP 发送失败: {e}"))?;
        Ok(())
    }
}

/// Deterministic in-memory email sink for integration tests.
#[derive(Clone, Default)]
pub struct MemoryEmailSender {
    sent: Arc<Mutex<Vec<OutgoingEmail>>>,
}

impl MemoryEmailSender {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn take_sent(&self) -> Vec<OutgoingEmail> {
        let mut guard = self.sent.lock().unwrap_or_else(|p| p.into_inner());
        std::mem::take(&mut *guard)
    }
}

#[async_trait]
impl EmailSender for MemoryEmailSender {
    async fn send(&self, _smtp: &SmtpSettings, email: &OutgoingEmail) -> anyhow::Result<()> {
        let mut guard = self.sent.lock().unwrap_or_else(|p| p.into_inner());
        guard.push(email.clone());
        Ok(())
    }
}

pub fn build_verification_email(to: &str, code: &str, purpose: &str) -> OutgoingEmail {
    let (title, action) = match purpose {
        "reset_password" => ("重置密码验证码", "重置你的 DropDrawer 账号密码"),
        _ => ("注册邮箱验证码", "完成 DropDrawer 新账号注册"),
    };
    let subject = format!("[DropDrawer] {title}：{code}");
    let text_body = format!(
        "你好，\n\n你正在{action}。你的 6 位验证码是：{code}\n\n验证码 10 分钟内有效，请勿向他人泄露。如非本人操作，请忽略此邮件。\n\n— DropDrawer"
    );
    let html_body = format!(
        r#"<!DOCTYPE html>
<html lang="zh-CN">
<body style="margin:0;padding:24px;background:#0e1015;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',sans-serif;color:#f5f5f7;">
  <div style="max-width:460px;margin:0 auto;background:#1c1c20;border:1px solid rgba(255,255,255,0.12);border-radius:16px;padding:28px;">
    <div style="font-size:15px;font-weight:600;color:#38bdf8;margin-bottom:14px;">DropDrawer</div>
    <h2 style="margin:0 0 10px;font-size:19px;color:#ffffff;">{title}</h2>
    <p style="margin:0 0 20px;font-size:14px;line-height:1.6;color:rgba(235,235,245,0.75);">你正在{action}，请在客户端输入以下 6 位验证码：</p>
    <div style="text-align:center;font-size:32px;font-weight:700;letter-spacing:8px;padding:16px 20px;border-radius:12px;background:#0f172a;color:#ffffff;border:1px solid rgba(56,189,248,0.35);">{code}</div>
    <p style="margin:20px 0 0;font-size:12px;color:rgba(235,235,245,0.5);">验证码 10 分钟内有效，最多可验证 5 次。如非本人操作请忽略此邮件。</p>
  </div>
</body>
</html>"#
    );
    OutgoingEmail {
        to: to.trim().to_string(),
        subject,
        text_body,
        html_body,
    }
}

pub fn build_test_email(to: &str) -> OutgoingEmail {
    OutgoingEmail {
        to: to.trim().to_string(),
        subject: "[DropDrawer] SMTP 邮件服务测试成功".to_string(),
        text_body: "你好，这是一封来自 DropDrawer 管理端的测试邮件。如果你收到了这封邮件，说明 SMTP 发信配置已正常工作。".to_string(),
        html_body: r#"<!DOCTYPE html>
<html lang="zh-CN">
<body style="margin:0;padding:24px;background:#0e1015;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',sans-serif;color:#f5f5f7;">
  <div style="max-width:460px;margin:0 auto;background:#1c1c20;border:1px solid rgba(255,255,255,0.12);border-radius:16px;padding:28px;">
    <div style="font-size:15px;font-weight:600;color:#38bdf8;margin-bottom:12px;">DropDrawer Admin</div>
    <h2 style="margin:0 0 10px;font-size:18px;color:#ffffff;">SMTP 邮件配置测试成功</h2>
    <p style="margin:0;font-size:14px;line-height:1.6;color:rgba(235,235,245,0.75);">如果你收到了这封邮件，说明服务器 SMTP 发信通道工作正常，可以放心启用邮箱验证码注册与自助找回密码功能。</p>
  </div>
</body>
</html>"#.to_string(),
    }
}
