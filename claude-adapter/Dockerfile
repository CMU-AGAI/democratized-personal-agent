FROM node:20-bookworm-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Python runtime (for the FastAPI app) + the Claude Code CLI (drives Claude via
# the Max subscription, so no Anthropic API key/credits are used).
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip python3-venv ca-certificates git \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code

RUN useradd -m -u 10003 appuser

WORKDIR /app
COPY requirements.txt .
RUN python3 -m pip install --no-cache-dir --break-system-packages -r requirements.txt

COPY app.py .

# .claude must exist and be owned by appuser BEFORE the named volume mounts over
# it, so the volume inherits appuser ownership (Docker seeds empty volumes from
# the image dir's contents + permissions).
RUN mkdir -p /workspace/input /workspace/qwen-data /workspace/out /home/appuser/.claude \
 && chown -R appuser:appuser /app /workspace/out /home/appuser
USER appuser

ENV HOME=/home/appuser
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
