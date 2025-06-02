#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Docker Hub 镜像爬虫
这个脚本用于从 Docker Hub 网站爬取镜像信息，包括官方镜像和用户镜像。
它会遍历不同的分类，提取镜像名称和标签，并将结果保存到文件中。
"""

import requests
import json
import re
import time
import os
import random
import sys
from datetime import datetime


class DockerHubCrawler:
    """
    Docker Hub 爬虫类
    用于爬取 Docker Hub 网站上的镜像信息
    """

    def __init__(self, max_pages=None):
        # 设置请求头，模拟浏览器访问
        self.headers = {
            "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"
        }
        self.base_url = "https://hub.docker.com"
        self.categories = []
        self.extracted_images = {}
        # 优先使用传入的参数，其次使用环境变量MAX_PAGES_PER_CATEGORY，最后使用默认值
        self.max_pages = max_pages if max_pages is not None else int(
            os.getenv('MAX_PAGES_PER_CATEGORY', 5))
        print(f"使用最大页数: {self.max_pages} (来自环境变量 MAX_PAGES_PER_CATEGORY)")

    def extract_json_from_html(self, html_content):
        """
        从HTML内容中提取JSON数据
        参数:
            html_content: 网页的HTML内容
        返回:
            解析后的JSON数据，如果解析失败则返回None
        """
        match = re.search(
            r'window\.__reactRouterContext\.streamController\.enqueue\(\s*\"(.*?)\"\s*\)\s*;',
            html_content, re.DOTALL)
        if match:
            json_string_escaped = match.group(1)
            try:
                json_string = json_string_escaped.encode().decode(
                    'unicode_escape')
                json_string = json_string.replace('\\"',
                                                  '"').replace('\\\\', '\\')
                return json.loads(json_string)
            except json.JSONDecodeError as e:
                print(f"JSON解析错误: {e}")
                return None
        return None

    def extract_categories_from_data(self, data_array):
        """
        从数据数组中提取分类信息
        参数:
            data_array: 包含分类信息的数组
        返回:
            提取出的分类列表，每个分类包含名称、slug和URL
        """
        categories_list = []
        i = 0
        found_categories_key = False

        while i < len(data_array):
            if not found_categories_key and isinstance(
                    data_array[i], str) and data_array[i] == "categories":
                found_categories_key = True
                if i + 1 < len(data_array) and isinstance(
                        data_array[i + 1], list):
                    ref_list = data_array[i + 1]
                    current_parse_index = i + 2

                    while current_parse_index < len(data_array):
                        current_element = data_array[current_parse_index]
                        is_obj_marker = isinstance(current_element, dict) and \
                                      any(k.startswith('_') for k in current_element.keys())

                        if is_obj_marker:
                            category_name = None
                            category_slug = None
                            consumed_elements = 0

                            if (current_parse_index + 4 < len(data_array)
                                    and data_array[current_parse_index + 1]
                                    == "name" and isinstance(
                                        data_array[current_parse_index + 2],
                                        str)
                                    and data_array[current_parse_index + 3]
                                    == "slug" and isinstance(
                                        data_array[current_parse_index + 4],
                                        str)):

                                category_name = data_array[current_parse_index
                                                           + 2]
                                category_slug = data_array[current_parse_index
                                                           + 4]
                                consumed_elements = 5

                            elif (current_parse_index + 2 < len(data_array)
                                  and isinstance(
                                      data_array[current_parse_index + 1], str)
                                  and isinstance(
                                      data_array[current_parse_index + 2],
                                      str)):

                                category_name = data_array[current_parse_index
                                                           + 1]
                                category_slug = data_array[current_parse_index
                                                           + 2]
                                consumed_elements = 3

                            else:
                                break

                            if category_name and category_slug:
                                category = {
                                    "name":
                                    category_name,
                                    "slug":
                                    category_slug,
                                    "url":
                                    f"{self.base_url}/search?categories={category_slug}"
                                }
                                categories_list.append(category)
                                current_parse_index += consumed_elements
                            else:
                                break
                        else:
                            break

                        i = current_parse_index
                        continue
                    else:
                        break
            i += 1

        return categories_list

    def extract_images_from_data(self, data_array, category_name):
        """
        从数据数组中提取镜像信息
        参数:
            data_array: 包含镜像信息的数组
            category_name: 当前处理的分类名称
        返回:
            images: 提取出的镜像列表
            total_items: 总镜像数
            total_pages: 总页数
            current_page_num: 当前页码
        """
        if not data_array:
            return [], 0, 0, 0

        images = []
        total_items = 0
        page_size = 25
        current_page_num = 1

        search_results_idx = -1
        results_ref_indices = None

        for i, item in enumerate(data_array):
            if isinstance(item, str) and item == "searchResults":
                search_results_idx = i
                break

        if search_results_idx == -1:
            return [], 0, 0, 0

        if not (search_results_idx + 5 < len(data_array)
                and isinstance(data_array[search_results_idx + 1], dict)
                and data_array[search_results_idx + 2] == "total"
                and isinstance(data_array[search_results_idx + 3], int)
                and data_array[search_results_idx + 4] == "results"
                and isinstance(data_array[search_results_idx + 5], list)):
            return [], 0, 0, 0

        total_items = data_array[search_results_idx + 3]
        results_ref_indices = data_array[search_results_idx + 5]

        for i, marker_index_ref in enumerate(results_ref_indices):
            actual_marker_index = -1
            img_obj_marker = None

            if isinstance(marker_index_ref,
                          int) and marker_index_ref < len(data_array):
                actual_marker_index = marker_index_ref
                if isinstance(data_array[actual_marker_index], dict) and \
                   any(k.startswith('_') for k in data_array[actual_marker_index].keys()):
                    img_obj_marker = data_array[actual_marker_index]

            if i == 0:
                current_processing_idx = search_results_idx + 6
                if current_processing_idx < len(data_array) and \
                   isinstance(data_array[current_processing_idx], dict) and \
                   any(k.startswith('_') for k in data_array[current_processing_idx].keys()):
                    img_obj_marker = data_array[current_processing_idx]
                    actual_marker_index = current_processing_idx
                else:
                    continue

            if not img_obj_marker and actual_marker_index != -1:
                pass
            elif not img_obj_marker:
                if i > 0:
                    break
                if not img_obj_marker:
                    continue

            image_id_val = None

            if i == 0:
                scan_start_index = actual_marker_index + 1
                scan_end = min(len(data_array), scan_start_index + 10)
                for k_idx in range(scan_start_index, scan_end - 1):
                    if data_array[k_idx] == "id" and isinstance(
                            data_array[k_idx + 1], str):
                        image_id_val = data_array[k_idx + 1]
                        break
            else:
                if actual_marker_index + 1 < len(data_array) and isinstance(
                        data_array[actual_marker_index + 1], str):
                    potential_id = data_array[actual_marker_index + 1]
                    if '/' in potential_id or not any(c.isspace()
                                                      for c in potential_id):
                        image_id_val = potential_id

            if image_id_val:
                images.append(image_id_val)
            else:
                if i == 0:
                    break

        paging_idx = -1
        for i, item in enumerate(data_array):
            if isinstance(item, str) and item == "paging":
                paging_idx = i
                break
        if paging_idx != -1:
            if (paging_idx + 5 < len(data_array)
                    and isinstance(data_array[paging_idx + 1], dict)
                    and data_array[paging_idx + 2] == "page"
                    and isinstance(data_array[paging_idx + 3], int)
                    and data_array[paging_idx + 4] == "pageSize"
                    and isinstance(data_array[paging_idx + 5], int)):
                current_page_num = data_array[paging_idx + 3]
                page_size = data_array[paging_idx + 5]

        total_pages = (total_items + page_size -
                       1) // page_size if page_size > 0 else 0

        return images, total_items, total_pages, current_page_num

    def get_images_for_category(self,
                                category_url,
                                category_name,
                                max_pages=None):
        """
        获取指定分类的镜像列表
        参数:
            category_url: 分类页面的URL
            category_name: 分类名称
            max_pages: 最大爬取页数，None表示不限制
        返回:
            该分类下的所有镜像列表
        """
        all_images_in_category = []
        current_page = 1

        try:
            while True:
                if '?' in category_url:
                    page_url = f"{category_url}&page={current_page}"
                else:
                    page_url = f"{category_url}?page={current_page}"

                print(f"正在获取第 {current_page} 页: {page_url}")
                response = requests.get(page_url,
                                        headers=self.headers,
                                        timeout=15)
                response.raise_for_status()

                html_content = response.text
                data_array = self.extract_json_from_html(html_content)

                if data_array:
                    images, total_items, total_pages, _ = self.extract_images_from_data(
                        data_array, category_name)

                    print(
                        f"分类 '{category_name}' (第 {current_page}/{total_pages} 页，共 {total_items} 个项目): 找到 {len(images)} 个镜像。"
                    )
                    if images:
                        for img_name in images:
                            print(f"  - {img_name}")
                        all_images_in_category.extend(images)

                    if max_pages and current_page >= max_pages:
                        print(f"已达到指定的最大页数 {max_pages}，停止提取。")
                        break

                    if current_page >= total_pages:
                        break

                    current_page += 1
                    time.sleep(3)
                else:
                    break

            return all_images_in_category

        except requests.exceptions.RequestException as e:
            print(f"抓取分类 '{category_name}' 页面时出错: {e}")
            return []

    def remove_duplicates(self, results):
        """
        移除重复的镜像记录
        参数:
            results: 包含镜像信息的字典
        返回:
            去重后的镜像信息字典
        """
        seen = set()
        new_results = {}
        for category, images in results.items():
            unique_images = []
            for img in images:
                if img not in seen:
                    unique_images.append(img)
                    seen.add(img)
            new_results[category] = unique_images
        return new_results

    def save_results_to_file(self, results, filename=None):
        """
        将爬取结果保存到文件
        参数:
            results: 要保存的镜像信息
            filename: 输出文件名，如果为None则使用默认命名
        """
        if not filename:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"/app/output/docker_images_{timestamp}.txt"

        # 确保输出目录存在
        os.makedirs(os.path.dirname(filename), exist_ok=True)

        # 随机化镜像列表顺序
        image_list = []
        for category, images in results.items():
            for image in images:
                image_list.append(f"{image}:latest")

        # 打乱镜像列表顺序
        random.shuffle(image_list)

        # 写入文件
        with open(filename, "w", encoding="utf-8") as f:
            for image in image_list:
                f.write(f"{image}\n")

        print(f"结果已保存到文件: {filename}")
        return filename

    def crawl_categories(self, max_pages=None):
        """
        爬取所有分类的镜像信息
        参数:
            max_pages: 每个分类最多爬取的页数，如果为None则使用环境变量中的值
        返回:
            所有分类的镜像信息
        """
        if max_pages is None:
            max_pages = self.max_pages

        all_results = []
        try:
            # 获取分类列表
            response = requests.get(self.base_url,
                                    headers=self.headers,
                                    timeout=10)
            response.raise_for_status()
            html_content = response.text

            data_array = self.extract_json_from_html(html_content)
            if data_array:
                self.categories = self.extract_categories_from_data(data_array)

                if self.categories:
                    print("\n成功提取到分类信息：")
                    for category in self.categories:
                        print(
                            f"  名称: {category['name']}, Slug: {category['slug']}, URL: {category['url']}"
                        )

                        # 获取每个分类的镜像
                        images_list = self.get_images_for_category(
                            category['url'], category['name'], max_pages)
                        if images_list:
                            self.extracted_images[
                                category['name']] = images_list

                        if category != self.categories[-1]:
                            print(f"完成分类 '{category['name']}'，等待3秒...")
                            time.sleep(3)
                else:
                    print("未找到或未能完整提取分类信息。")
            else:
                print("未能在 HTML 中找到预期的嵌入式 JSON 数据。")

        except requests.exceptions.RequestException as req_err:
            print(f"请求发生错误: {req_err}")
        except Exception as e:
            print(f"发生了一个预料之外的错误: {e}")
            import traceback
            traceback.print_exc()

        # 保存结果
        if self.extracted_images:
            self.save_results_to_file(self.extracted_images)

        print("\n脚本执行完毕。")


def main():
    # 从环境变量获取最大页数
    max_pages = None
    if os.getenv('MAX_PAGES_PER_CATEGORY'):
        try:
            max_pages = int(os.getenv('MAX_PAGES_PER_CATEGORY'))
            print(f"从环境变量 MAX_PAGES_PER_CATEGORY 读取到最大页数: {max_pages}")
        except ValueError:
            print(
                f"警告: 环境变量 MAX_PAGES_PER_CATEGORY 的值无效: '{os.getenv('MAX_PAGES_PER_CATEGORY')}'，将使用默认值"
            )

    crawler = DockerHubCrawler(max_pages)
    results = crawler.crawl_categories()
    if results:
        print(f"已达到指定的最大页数 {crawler.max_pages}，停止提取。")
        crawler.save_results_to_file(results)
        print("脚本执行完毕。")
    else:
        print("未找到任何镜像信息。")


if __name__ == "__main__":
    main()
