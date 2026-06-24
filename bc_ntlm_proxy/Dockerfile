FROM python:3.12-slim
RUN pip install flask requests requests-ntlm --no-cache-dir
COPY proxy.py /app/proxy.py
WORKDIR /app
CMD ["python", "proxy.py"]
