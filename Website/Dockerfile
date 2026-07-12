# Step 1: Use the official lightweight Nginx alpine image
FROM nginx:alpine

# Step 2: Clean out any default website files provided by Nginx
RUN rm -rf /usr/share/nginx/html/*

# Step 3: Copy your local website files into the Nginx HTML directory
COPY ./html /usr/share/nginx/html

# Step 4: Inform Docker that the container listens on port 80 at runtime
EXPOSE 80

# Step 5: Start Nginx in the foreground so the container stays active
CMD ["nginx", "-g", "daemon off;"]